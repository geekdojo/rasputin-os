#!/bin/sh
# Functional test for the image's core-dump policy, against REAL systemd 256.17
# -- the version Buildroot 2025.02.17 builds into the image -- and the real
# drop-ins and units from the rootfs overlay.
#
# WHY THIS EXISTS. The policy is entirely configuration: which unit may write a
# core, where it lands, and who can read it. Nothing in a build or a shell
# check can show whether systemd agrees with our reading of it, and the premise
# the old configuration rested on turned out to be wrong -- systemd has raised
# RLIMIT_CORE to infinity for PID 1 and every service it forks since v215, so
# the drop-in that "enabled" core dumps was a no-op and every service on the
# image could dump. Scenario 1 pins that so the next reader does not have to
# take it on trust, and fails if a future systemd changes its default again.
#
# Scenarios, all in one container (each is independent of the others):
#   1  systemd's own default IS infinity, and our drop-in lowers it to 0
#   2  rasputin-agent.service raises it back, and a child it spawns inherits it
#   3  a child of rasputin-agent.service that aborts leaves a core; the same
#      crash under a unit with no LimitCORE stanza leaves none
#   4  the coredump store is 0700 root, created by the real store unit
#   5  a core stored through the real systemd-coredump socket path ends up
#      0600, the store is still 0700, and the coredump unit did not fail
#   6  a pre-existing wider-mode file in the store is tightened by the next dump
#
# NOT COVERED, and only the bench can cover it: the kernel handing a core to
# systemd-coredump. The kernel runs the core_pattern helper in the INITIAL
# namespace, so a crash inside a container never reaches the container's
# handler. Scenario 3 therefore points core_pattern at a plain file to observe
# what RLIMIT_CORE allows, and scenario 5 drives the real systemd-coredump
# entry point directly, which forwards over /run/systemd/coredump to
# systemd-coredump@.service exactly as a kernel-spawned one does. The wiring
# between the two -- core_pattern pointing at systemd-coredump -- is systemd's
# own sysctl.d drop-in, which this image does not modify.
#
# Needs: docker, with privileged containers. Linux runner or Docker Desktop.
# Run:   sh test/coredump-functional.sh
#
# THIS TEST CHANGES kernel.core_pattern ON THE DOCKER HOST for part of the run
# (the sysctl is global, not per-namespace) and restores the original value on
# exit, including on failure.
#
# Every wait below has a deadline and fails naming the fact that never became
# true. The deadlines bound the test; the units under test use none.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IMAGE=rasputin-coredump-functional:f41-systemd-256.17
DEADLINE="${COREDUMP_TEST_DEADLINE:-60}"
STORE=/var/lib/systemd/coredump
BACKING=/var/lib/rasputin/coredump
KERNEL_CORES=/tmp/rasputin-kernel-core
# %c, the crashing process's core-size soft limit, as the kernel passes it for
# an unlimited one. systemd-coredump refuses to store anything when this is
# below a page, so it cannot be left at 0.
RLIMIT_INFINITY=18446744073709551615

command -v docker >/dev/null 2>&1 || { echo "docker not found - this test needs docker with privileged containers"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}
ok_if() { # ok_if "<label>" <condition-exit-status> "<detail>"
	check "$1" "$2" "${3:-}"
}

# Fedora 41 ships systemd 256.17, the same release as the image, so what
# systemd does with these drop-ins here is what it does on a node, not a guess.
# The build fails loudly if that exact version is no longer installable.
echo "building test image ($IMAGE)"
docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE' || { echo "FAILED: could not build the test image"; exit 1; }
FROM fedora:41
RUN dnf -y install --setopt=install_weak_deps=False \
      systemd-256.17 systemd-udev-256.17 \
      util-linux procps-ng findutils \
 && dnf clean all \
 && systemctl mask systemd-resolved.service systemd-homed.service systemd-userdbd.service \
      systemd-networkd.service dnf-makecache.timer
STOPSIGNAL SIGRTMIN+3
CMD ["/usr/sbin/init"]
DOCKERFILE

CID=""
# Captured BEFORE the test container boots. kernel.core_pattern is a global
# sysctl with no namespace of its own, and systemd sets it from its own
# sysctl.d the moment it starts as PID 1 — so reading it from inside the
# running container would save systemd's value, not the host's, and "restoring"
# it would leave the host pointing at a binary the host does not have. This
# runs the test image's shell rather than its init, so nothing is started.
SAVED_PATTERN=$(docker run --rm --privileged "$IMAGE" sh -c 'cat /proc/sys/kernel/core_pattern' 2>/dev/null)
[ -n "$SAVED_PATTERN" ] || { echo "FAILED: could not read the host's kernel.core_pattern"; exit 1; }
echo "host kernel.core_pattern is '$SAVED_PATTERN'; it will be restored on exit"

restore_pattern() {
	[ -n "$CID" ] && [ -n "$SAVED_PATTERN" ] || return 0
	docker exec "$CID" sh -c 'printf "%s\n" "$1" > /proc/sys/kernel/core_pattern' _ "$SAVED_PATTERN" >/dev/null 2>&1
}
cleanup() {
	restore_pattern
	[ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1
	CID=""
}
trap cleanup EXIT INT TERM

inside() { docker exec "$CID" sh -c "$*"; }

# wait_for "what should become true" 'shell condition run inside the container'
wait_for() {
	i=0
	while [ "$i" -lt "$DEADLINE" ]; do
		inside "$2" >/dev/null 2>&1 && return 0
		sleep 1
		i=$((i + 1))
	done
	echo "  DEADLINE: after ${DEADLINE}s, still not true: $1"
	return 1
}

CID=$(docker run -d --privileged --cgroupns=private \
	--tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
	-v "$OVERLAY:/overlay:ro" "$IMAGE") || { echo "FAILED: could not start container"; exit 1; }
wait_for "systemd is running in the container" \
	's=$(systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ]' || exit 1
echo "in the container: $(inside 'systemctl --version | head -1')"

echo
echo "1. systemd's default is infinity; the drop-in lowers it"

# Measured BEFORE our drop-in is installed: this is stock systemd.
stock_default=$(inside "systemctl show -p DefaultLimitCORESoft --value")
ok_if "stock systemd defaults RLIMIT_CORE soft to infinity (got '$stock_default') - the drop-in is load-bearing" \
	"$([ "$stock_default" = infinity ] && echo 0 || echo 1)" \
	"if this ever stops being infinity, re-read etc/systemd/system.conf.d/rasputin-coredump.conf"

# --- install exactly what the image installs ------------------------------
#
# The overlay is copied in verbatim. Everything marked TEST HARNESS is not from
# the image: the agent binary and rasputin-firstboot are not on this container,
# and /var/lib/rasputin has to be a mountpoint for the store unit's condition.
inside "
set -e
install -D -m 0644 /overlay/etc/systemd/system.conf.d/rasputin-coredump.conf /etc/systemd/system.conf.d/rasputin-coredump.conf
install -D -m 0644 /overlay/etc/systemd/coredump.conf.d/rasputin.conf /etc/systemd/coredump.conf.d/rasputin.conf
install -D -m 0644 '/overlay/etc/systemd/system/systemd-coredump@.service.d/rasputin-coredump.conf' \
    '/etc/systemd/system/systemd-coredump@.service.d/rasputin-coredump.conf'
install -D -m 0755 /overlay/usr/lib/rasputin/coredump/coredump-restrict-mode.sh \
    /usr/lib/rasputin/coredump/coredump-restrict-mode.sh
install -D -m 0644 /overlay/etc/systemd/system/rasputin-agent.service /etc/systemd/system/rasputin-agent.service
install -D -m 0644 /overlay/etc/systemd/system/rasputin-coredump-store.service /etc/systemd/system/rasputin-coredump-store.service

# TEST HARNESS: stands in for /usr/bin/rasputin-agent and for anything else on
# the image. Records what a CHILD of the unit's main process inherits -- the
# rauc install is such a child -- then makes one abort the way the #8
# double-free does, then idles so the unit stays active.
cat >/usr/local/bin/rasputin-unit-stub <<'EOF'
#!/bin/sh
tag=\"\$1\"
sh -c 'grep \"Max core file size\" /proc/self/limits' > \"/run/child-limits.\$tag\"
/usr/local/bin/selfabort >/dev/null 2>&1
exec sleep infinity
EOF
chmod 0755 /usr/local/bin/rasputin-unit-stub
printf '#!/bin/sh\nkill -ABRT \$\$\n' > /usr/local/bin/selfabort
chmod 0755 /usr/local/bin/selfabort

# TEST HARNESS: rasputin-agent.service Requires= it, and it is not here.
cat >/etc/systemd/system/rasputin-firstboot.service <<'EOF'
[Unit]
Description=TEST HARNESS stub for rasputin-firstboot.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/true
EOF
# TEST HARNESS: the agent binary is not on this image, and Type=notify would
# never be satisfied by a stub. Everything else in the unit, LimitCORE
# included, is the image's.
install -d /etc/systemd/system/rasputin-agent.service.d
cat >/etc/systemd/system/rasputin-agent.service.d/zz-test-harness.conf <<'EOF'
[Service]
Type=simple
WatchdogSec=0
Restart=no
ExecStart=
ExecStart=/usr/local/bin/rasputin-unit-stub agent
EOF
# The control: what every other service on the image now looks like -- no
# LimitCORE stanza at all.
cat >/etc/systemd/system/rasputin-control-probe.service <<'EOF'
[Unit]
Description=Control: a unit that does NOT raise the core limit
[Service]
Type=simple
ExecStart=/usr/local/bin/rasputin-unit-stub control
EOF
# TEST HARNESS: the store unit requires /var/lib/rasputin to be a mountpoint.
install -d -m 0755 /var/lib/rasputin
mount -o bind /var/lib/rasputin /var/lib/rasputin
systemctl daemon-reexec
systemctl daemon-reload
" || { echo "FAILED: could not install the overlay into the container"; exit 1; }

mgr_default=$(inside "systemctl show -p DefaultLimitCORESoft --value")
ok_if "the drop-in lowers the manager default to 0 (got '$mgr_default')" \
	"$([ "$mgr_default" = 0 ] && echo 0 || echo 1)"
mgr_hard=$(inside "systemctl show -p DefaultLimitCORE --value")
ok_if "the hard limit stays infinity so a unit can raise its own (got '$mgr_hard')" \
	"$([ "$mgr_hard" = infinity ] && echo 0 || echo 1)"

echo
echo "2. rasputin-agent.service raises it back"

agent_soft=$(inside "systemctl show rasputin-agent.service -p LimitCORESoft --value")
ok_if "rasputin-agent.service LimitCORESoft=infinity (got '$agent_soft')" \
	"$([ "$agent_soft" = infinity ] && echo 0 || echo 1)"

# Point the kernel at a plain file so a core, if the kernel is allowed to write
# one, lands where this test can see it. With the default pipe pattern the
# handler runs in the initial namespace and never reaches this container.
inside "printf '%s\n' '$KERNEL_CORES.%e.%p' > /proc/sys/kernel/core_pattern; rm -f $KERNEL_CORES.*" >/dev/null 2>&1

inside "systemctl start rasputin-agent.service" >/dev/null 2>&1
wait_for "rasputin-agent.service is running" "systemctl is-active --quiet rasputin-agent.service" || fails=$((fails + 1))
agent_main=$(inside "grep 'Max core file size' /proc/\$(systemctl show rasputin-agent.service -p MainPID --value)/limits" 2>/dev/null)
case "$agent_main" in
	*unlimited*unlimited*) check "the agent process itself has RLIMIT_CORE unlimited" 0 ;;
	*) check "the agent process itself has RLIMIT_CORE unlimited" 1 "${agent_main:-<no output>}" ;;
esac
wait_for "the agent's child has reported its limits" "test -s /run/child-limits.agent" || fails=$((fails + 1))
agent_child=$(inside "cat /run/child-limits.agent" 2>/dev/null)
case "$agent_child" in
	*unlimited*unlimited*) check "a CHILD of the agent inherits it - this is the rauc install" 0 ;;
	*) check "a CHILD of the agent inherits it - this is the rauc install" 1 "${agent_child:-<no output>}" ;;
esac

echo
echo "3. the rauc-shaped crash still dumps, and nothing else does"

wait_for "the agent's aborting child left a core" "ls $KERNEL_CORES.selfabort.* >/dev/null 2>&1" \
	&& check "a child of rasputin-agent.service that aborts leaves a core" 0 \
	|| check "a child of rasputin-agent.service that aborts leaves a core" 1 "nothing at $KERNEL_CORES.*"

inside "systemctl start rasputin-control-probe.service" >/dev/null 2>&1
wait_for "the control unit is running" "systemctl is-active --quiet rasputin-control-probe.service" || fails=$((fails + 1))
ctl_child=$(inside "cat /run/child-limits.control" 2>/dev/null)
case "$ctl_child" in
	*unlimited*unlimited*) check "a child of the control unit does NOT get unlimited" 1 "$ctl_child" ;;
	'') check "a child of the control unit does NOT get unlimited" 1 "<no output>" ;;
	*) check "a child of the control unit does NOT get unlimited ($ctl_child)" 0 ;;
esac
# The control unit's child aborted too. Give the kernel the same room the
# positive case got, then assert it wrote nothing for it.
i=0
while [ "$i" -lt 5 ]; do inside "ls $KERNEL_CORES.selfabort.* >/dev/null 2>&1" && break; sleep 1; i=$((i + 1)); done
core_count=$(inside "ls $KERNEL_CORES.selfabort.* 2>/dev/null | wc -l" | tr -d ' ')
ok_if "exactly one core exists - the control unit's identical crash wrote none (got $core_count)" \
	"$([ "$core_count" = 1 ] && echo 0 || echo 1)" \
	"$(inside "ls -l $KERNEL_CORES.* 2>/dev/null" | tr '\n' '|')"

restore_pattern

echo
echo "4. the store is 0700 root"

inside "systemctl start rasputin-coredump-store.service" >/dev/null 2>&1
wait_for "the coredump store unit has run" "systemctl is-active --quiet rasputin-coredump-store.service" || fails=$((fails + 1))
backing_mode=$(inside "stat -c '%a %U' $BACKING" 2>/dev/null)
ok_if "$BACKING is 0700 root (got '$backing_mode')" \
	"$([ "$backing_mode" = "700 root" ] && echo 0 || echo 1)"
mounted=$(inside "mountpoint -q $STORE && echo yes || echo no")
ok_if "$STORE is the bind-mounted store (got $mounted)" \
	"$([ "$mounted" = yes ] && echo 0 || echo 1)"

echo
echo "5. a stored core is 0600, and the store stays 0700"

# Hand the real core from scenario 3 to the real systemd-coredump, which
# forwards it over /run/systemd/coredump to systemd-coredump@.service -- the
# unit the drop-in under test applies to.
#
# The process named by %P must be alive (systemd-coredump reads /proc/<pid> for
# metadata) and must be in a service cgroup: a process in init.scope is treated
# as PID 1 having crashed, which takes the in-process path instead of the
# socket and would not exercise the unit at all.
stored=$(inside "
set -e
rm -f $STORE/core.*
core=\$(ls $KERNEL_CORES.selfabort.* | head -1)
systemd-run --quiet --unit=coredump-victim /bin/sleep 300
for i in \$(seq 1 $DEADLINE); do
  v=\$(systemctl show coredump-victim.service -p MainPID --value); [ \"\$v\" != 0 ] && break
  sleep 1
done
/usr/lib/systemd/systemd-coredump \"\$v\" 0 0 6 \$(date +%s) $RLIMIT_INFINITY \$(cat /proc/sys/kernel/hostname) 1 < \"\$core\" || true
for i in \$(seq 1 $DEADLINE); do
  ls $STORE/core.* >/dev/null 2>&1 && break
  sleep 1
done
systemctl stop coredump-victim.service >/dev/null 2>&1 || true
ls $STORE/core.* 2>/dev/null | head -1
")
if [ -z "$stored" ]; then
	check "a core handed to systemd-coredump is stored" 1 \
		"nothing appeared in $STORE; last journal: $(inside 'journalctl --no-pager -n 6 -t systemd-coredump' 2>/dev/null | tr '\n' '|')"
else
	check "a core handed to systemd-coredump is stored ($(basename "$stored"))" 0
	core_mode=$(inside "stat -c '%a %U' '$stored'")
	ok_if "the stored core is 0600 root (got '$core_mode')" \
		"$([ "$core_mode" = "600 root" ] && echo 0 || echo 1)"
	store_mode=$(inside "stat -c '%a %U' $STORE")
	ok_if "the store is still 0700 root after a dump (got '$store_mode')" \
		"$([ "$store_mode" = "700 root" ] && echo 0 || echo 1)"
	# A failed ExecStopPost would leave the instance in `failed`, which is how
	# a broken restrict-mode script must show up rather than silently.
	failed=$(inside "systemctl list-units 'systemd-coredump@*' --all --plain --no-legend 2>/dev/null | grep -c failed" | tr -d ' ')
	ok_if "no systemd-coredump@ instance failed (got $failed)" \
		"$([ "$failed" = 0 ] && echo 0 || echo 1)" \
		"$(inside "systemctl list-units 'systemd-coredump@*' --all --plain --no-legend" | tr '\n' '|')"
fi

echo
echo "6. a wider-mode file already in the store is tightened"

widened=$(inside "
set -e
: > $STORE/core.stale-from-an-older-image
chmod 0644 $STORE/core.stale-from-an-older-image
core=\$(ls $KERNEL_CORES.selfabort.* | head -1)
systemd-run --quiet --unit=coredump-victim2 /bin/sleep 300
for i in \$(seq 1 $DEADLINE); do
  v=\$(systemctl show coredump-victim2.service -p MainPID --value); [ \"\$v\" != 0 ] && break
  sleep 1
done
/usr/lib/systemd/systemd-coredump \"\$v\" 0 0 6 \$(date +%s) $RLIMIT_INFINITY \$(cat /proc/sys/kernel/hostname) 1 < \"\$core\" || true
for i in \$(seq 1 $DEADLINE); do
  [ \"\$(stat -c %a $STORE/core.stale-from-an-older-image)\" = 600 ] && break
  sleep 1
done
systemctl stop coredump-victim2.service >/dev/null 2>&1 || true
stat -c %a $STORE/core.stale-from-an-older-image
")
ok_if "a 0644 file already in the store becomes 0600 (got '$widened')" \
	"$([ "$widened" = "600" ] && echo 0 || echo 1)"

echo
if [ "$fails" -eq 0 ]; then
	echo "all coredump policy checks passed"
	exit 0
fi
echo "$fails check(s) FAILED"
exit 1
