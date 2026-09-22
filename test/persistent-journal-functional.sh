#!/bin/sh
# Functional test for persistent journal storage, against REAL systemd 256.17 —
# the version Buildroot 2025.02.17 builds into the image — using the journald
# drop-in and the tmpfiles file from the rootfs overlay exactly as they ship.
# geekdojo/geekdojo-brain#601.
#
# WHY THIS EXISTS. The change is nothing but systemd configuration, so nothing
# in a build and nothing in a shell check can say whether systemd reads it the
# way we do. Two claims in particular are readings of a manual page, and both
# are silent when wrong:
#
#   1. "journald with Storage=persistent writes into /var/log/journal once that
#      path is writable, and keeps writing to /run when it is not." The second
#      half of that is the defect being fixed — it is what every node has been
#      doing — so a test that cannot reproduce it cannot show the fix either.
#
#   2. "a tmpfiles.d file whose basename sorts after systemd.conf overrides
#      systemd.conf's mode for the same path." Stock systemd ships
#      `z /var/log/journal 2755 root systemd-journal`, systemd-tmpfiles-setup
#      runs after the journal flush, and the two lines land on the same inode.
#      If the reading is wrong, /var/log/journal is world-listable on every node
#      under a /var/log that is 0777, AND the at-rest audit fails on every boot
#      — but only once an image is built and booted. Both files are tried here,
#      the one that ships and the one that would have looked right in review.
#
# Scenarios, in one container:
#   0  the defect: /var/log/journal exists but is read-only (the squashfs
#      rootfs), so journald stays on /run and history dies with the boot
#   1  the fix: the store bind-mounted over it, and a message logged BEFORE the
#      flush is readable from the persistent journal after it
#   2  the store's mode survives journald creating its tree inside it
#   3  the retention cap this image sets is the cap real journald applies
#   4  tmpfiles: the shipped file wins over stock systemd.conf; the same line in
#      rasputin.conf does not
#
# NOT COVERED, and only a booted node can cover it: that the unit's ordering
# actually puts the bind mount in front of systemd-journal-flush.service on
# real hardware, and that the journal is still there after a reboot. The
# commands for that are in the pull request. This covers what journald and
# systemd-tmpfiles do with the files, which is the half that no reboot would
# explain if it went wrong.
#
# Needs: docker. Linux runner or Docker Desktop.
# Run:   sh test/persistent-journal-functional.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
JOURNALD_CONF="$OVERLAY/etc/systemd/journald.conf.d/rasputin.conf"
JOURNAL_TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/zz-rasputin-journal.conf"
IMAGE=rasputin-persistent-journal-functional:f41-systemd-256.17

for f in "$JOURNALD_CONF" "$JOURNAL_TMPFILES"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done
command -v docker >/dev/null 2>&1 || { echo "docker not found - this test needs docker"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
# Glob matching rather than expr(1): expr prints the match length on stdout, and
# these results are read through $(...), so its output would be captured
# alongside the verdict and every such check would read as a failure.
starts_with() { case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac; }
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Fedora 41 ships systemd 256.17, the same release as the image, so what
# journald and systemd-tmpfiles do with these files here is what they do on a
# node. Same base as test/console-shadow-functional.sh.
echo "building test image ($IMAGE)"
docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE' || { echo "FAILED: could not build the test image"; exit 1; }
FROM fedora:41
RUN dnf -y install --setopt=install_weak_deps=False systemd-256.17 util-linux findutils \
 && dnf clean all
DOCKERFILE

CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; CID=""; }
trap cleanup EXIT INT TERM

# --privileged for mount(2): the whole mechanism under test is a bind mount.
CID=$(docker run -d --privileged --tmpfs /run --tmpfs /tmp \
	-v "$OVERLAY:/overlay:ro" "$IMAGE" sleep 900) \
	|| { echo "FAILED: could not start container"; exit 1; }
inside() { docker exec "$CID" sh -c "$*"; }
echo "in the container: $(inside 'journalctl --version | head -1')"

# The image's own drop-in, copied in as shipped. Nothing here retypes its
# values: a cap edited in the overlay has to show up in scenario 3 or this test
# is describing a file that no longer exists.
inside 'mkdir -p /etc/systemd/journald.conf.d && cp /overlay/etc/systemd/journald.conf.d/rasputin.conf /etc/systemd/journald.conf.d/rasputin.conf' >/dev/null
# Test-only, and deliberately in its own file: --privileged gives the container
# the HOST's kernel ring buffer and audit stream, which would bury journald's
# own messages and make the run's duration depend on what the host was doing.
# Neither key is set by the image's drop-in, so nothing under test is
# overridden.
inside 'printf "[Journal]\nReadKMsg=no\nAudit=no\n" > /etc/systemd/journald.conf.d/zz-test-quiet.conf' >/dev/null
inside 'systemd-machine-id-setup' >/dev/null 2>&1
MID=$(inside 'cat /etc/machine-id')

# start_journald — the real daemon, with a bounded wait for the socket it
# creates. The deadline names what never became true and the loop gives up if
# the daemon died, rather than spinning until the CI job is killed.
start_journald() {
	inside 'rm -rf /run/log/journal /run/systemd/journal' >/dev/null 2>&1
	docker exec -d "$CID" sh -c '/usr/lib/systemd/systemd-journald >/tmp/journald.log 2>&1 & echo $! >/run/journald.pid'
	i=0
	while [ "$i" -lt 100 ]; do
		inside 'test -S /run/systemd/journal/socket' >/dev/null 2>&1 && return 0
		inside 'kill -0 "$(cat /run/journald.pid 2>/dev/null)" 2>/dev/null' >/dev/null 2>&1 || {
			echo "FAILED: systemd-journald exited before it created its socket"
			inside 'cat /tmp/journald.log'
			return 1
		}
		i=$((i + 1))
		sleep 0.1
	done
	echo "FAILED: /run/systemd/journal/socket never appeared within 10s"
	inside 'cat /tmp/journald.log'
	return 1
}
stop_journald() {
	inside 'kill "$(cat /run/journald.pid 2>/dev/null)" 2>/dev/null; rm -f /run/journald.pid' >/dev/null 2>&1
	return 0
}
# journal_path — where journald says it is writing. The single fact this whole
# change is about.
journal_path() { inside 'journalctl --header 2>/dev/null | sed -n "s/^File path: //p" | head -1'; }
# wait_for_path PREFIX — bounded wait for the journal to be under PREFIX.
wait_for_path() {
	i=0
	while [ "$i" -lt 100 ]; do
		case "$(journal_path)" in "$1"*) return 0 ;; esac
		i=$((i + 1))
		sleep 0.1
	done
	return 1
}
mode() { inside "stat -c %a '$1' 2>/dev/null"; }
owner() { inside "stat -c %U:%G '$1' 2>/dev/null"; }

echo
echo "0. the defect: /var/log/journal read-only, as it is on the squashfs rootfs"
# The mountpoint exists in the image — it is baked — but it is on /dev/root,
# which is a read-only squashfs that is 100% full. A read-only tmpfs over it is
# the same thing from journald's point of view: the directory is there and
# nothing can be created in it.
inside 'mkdir -p /var/log/journal && mount -t tmpfs -o ro,size=1M tmpfs /var/log/journal' >/dev/null
start_journald || exit 1
inside 'journalctl --flush' >/dev/null 2>&1
DEFECT_PATH=$(journal_path)
check "journald falls back to /run when the mountpoint is not writable" \
	"$(yes_if starts_with /run/log/journal/ "$DEFECT_PATH")" "File path: $DEFECT_PATH"
check "nothing is written under /var/log/journal" \
	"$(yes_if inside 'test -z "$(ls -A /var/log/journal 2>/dev/null)"')" \
	"$(inside 'ls -la /var/log/journal')"
stop_journald
inside 'umount /var/log/journal' >/dev/null

echo
echo "1. the fix: the persistent store bind-mounted over the mountpoint"
# What rasputin-journal-store.service does, in its order: create the store on
# the persistent partition, set its mode, bind-mount it over the baked
# mountpoint. Here the "persistent partition" is just a directory; what is
# under test is journald's behaviour, not ext4's.
inside 'mkdir -p /var/lib/rasputin/journal' >/dev/null
inside 'chmod 0700 /var/lib/rasputin/journal' >/dev/null
inside 'mount -o bind /var/lib/rasputin/journal /var/log/journal' >/dev/null
start_journald || exit 1
# Logged BEFORE the flush, i.e. while journald is still writing to /run. This
# is the boot's own log — the part an investigation wants and the part that has
# been dying on every reboot.
inside 'echo "entry-from-before-the-flush" | systemd-cat -t rasputin-journal-probe' >/dev/null
inside 'journalctl --flush' >/dev/null 2>&1
if wait_for_path /var/log/journal; then :; else
	echo "  (journal never moved to /var/log/journal within 10s)"
	inside 'cat /tmp/journald.log'
fi
FIX_PATH=$(journal_path)
check "journald writes into /var/log/journal" \
	"$(yes_if starts_with "/var/log/journal/$MID/" "$FIX_PATH")" "File path: $FIX_PATH"
check "the journal file is on the persistent store, not the mountpoint's own fs" \
	"$(yes_if inside "test -f /var/lib/rasputin/journal/$MID/system.journal")" \
	"$(inside 'find /var/lib/rasputin/journal -type f')"
check "an entry logged before the flush survives into the persistent journal" \
	"$(yes_if inside 'journalctl -t rasputin-journal-probe --no-pager -o cat 2>/dev/null | grep -q entry-from-before-the-flush')" \
	"$(inside 'journalctl -t rasputin-journal-probe --no-pager -o cat 2>&1 | head -5')"

echo
echo "2. the store's mode survives journald creating its tree in it"
check "the store is still 0700" "$(yes_if [ "$(mode /var/lib/rasputin/journal)" = 700 ])" \
	"mode=$(mode /var/lib/rasputin/journal)"
check "the store is still root:root" "$(yes_if [ "$(owner /var/lib/rasputin/journal)" = root:root ])" \
	"owner=$(owner /var/lib/rasputin/journal)"

echo
echo "3. the retention cap the image sets is the cap journald applies"
# journald states the system journal's limit in its own log the first time it
# opens it: "System Journal (...) is 8M, max 512M, 504M free." The expected
# value is READ OUT OF THE OVERLAY, so editing the drop-in without editing this
# test cannot leave a stale number asserted here.
WANT_MAXUSE=$(sed -n 's/^SystemMaxUse=//p' "$JOURNALD_CONF" | head -1)
SIZELINE=$(inside "journalctl -b --no-pager -o cat 2>/dev/null | grep -m1 '^System Journal'")
check "the drop-in names a SystemMaxUse" "$(yes_if test -n "$WANT_MAXUSE")" "$JOURNALD_CONF"
check "journald reported the system journal's limit" "$(yes_if test -n "$SIZELINE")" "$SIZELINE"
# journald renders the limit as it was configured — "max 512M," for
# SystemMaxUse=512M. Matched as a substring of journald's own line, so what is
# compared is the value the daemon is enforcing, not the value in the file.
check "journald applies the configured cap, not a filesystem-derived default" \
	"$(yes_if contains "max $WANT_MAXUSE," "$SIZELINE")" \
	"configured=$WANT_MAXUSE reported: $SIZELINE"
stop_journald
inside 'umount /var/log/journal' >/dev/null

echo
echo "4. tmpfiles: the shipped file has to beat stock systemd.conf"
# systemd-tmpfiles-setup.service runs AFTER systemd-journal-flush.service, so
# stock systemd.conf's `z /var/log/journal 2755 root systemd-journal` lands on
# the bind-mounted store on every boot. Files are read in lexicographic order of
# basename and, for two lines naming one path, the LAST applied wins — which is
# the entire reason the shipped file is named the way it is. Both arrangements
# are run: the one that ships, and the one that would have looked right.
check "stock systemd.conf really does carry the competing line" \
	"$(yes_if inside 'grep -qE "^z +/var/log/journal +2755 +root +systemd-journal" /usr/lib/tmpfiles.d/systemd.conf')" \
	"$(inside 'grep -n "var/log/journal" /usr/lib/tmpfiles.d/systemd.conf')"
TMPFILES_BASE=$(basename "$JOURNAL_TMPFILES")

# The shipped arrangement.
inside "rm -f /usr/lib/tmpfiles.d/$TMPFILES_BASE /usr/lib/tmpfiles.d/rasputin-journal-mode.conf" >/dev/null 2>&1
inside "cp /overlay/usr/lib/tmpfiles.d/$TMPFILES_BASE /usr/lib/tmpfiles.d/$TMPFILES_BASE" >/dev/null
inside 'chmod 2755 /var/log/journal && chgrp systemd-journal /var/log/journal' >/dev/null
inside 'systemd-tmpfiles --create' >/dev/null 2>&1
check "the shipped tmpfiles file leaves /var/log/journal at 0700" \
	"$(yes_if [ "$(mode /var/log/journal)" = 700 ])" "mode=$(mode /var/log/journal)"
check "it leaves it root:root" "$(yes_if [ "$(owner /var/log/journal)" = root:root ])" \
	"owner=$(owner /var/log/journal)"
# Twice: tmpfiles runs on every boot, and a line that only held the first time
# would be a mode that decays.
inside 'systemd-tmpfiles --create' >/dev/null 2>&1
check "a second tmpfiles run still leaves it 0700" \
	"$(yes_if [ "$(mode /var/log/journal)" = 700 ])" "mode=$(mode /var/log/journal)"

# The counterfactual: the same line in a file that sorts BEFORE systemd.conf,
# which is where it would naturally have been put (the image's other tmpfiles
# lines live in rasputin.conf). If this case ever passes, the sort-order
# reasoning is wrong in a way that makes the shipped name unnecessary — and
# nothing else would say so.
inside "rm -f /usr/lib/tmpfiles.d/$TMPFILES_BASE" >/dev/null
inside 'printf "z /var/log/journal 0700 root root - -\n" > /usr/lib/tmpfiles.d/rasputin.conf' >/dev/null
inside 'chmod 2755 /var/log/journal && chgrp systemd-journal /var/log/journal' >/dev/null
inside 'systemd-tmpfiles --create' >/dev/null 2>&1
check "the same line in rasputin.conf LOSES to systemd.conf (why the name sorts last)" \
	"$(yes_if [ "$(mode /var/log/journal)" = 2755 ])" "mode=$(mode /var/log/journal)"

echo
if [ "$fails" -eq 0 ]; then
	echo "persistent-journal-functional: all checks passed"
else
	echo "persistent-journal-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
