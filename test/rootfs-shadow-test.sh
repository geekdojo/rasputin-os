#!/bin/sh
#
# Tests for WHERE the /etc/shadow swap happens in the build, not just what it
# produces. geekdojo/geekdojo-brain#546.
#
# WHY THIS EXISTS. Commit cc74fb4 put the swap in post-build.sh, which replaces
# /etc/shadow with a DANGLING symlink onto the persistent partition. Buildroot
# is not finished with /etc/shadow at that point: the rootfs image rule then
# runs support/scripts/mkusers over the same tree, and mkusers deletes each
# package user's stale row with
#
#     sed -r -i --follow-symlinks -e '/^user:.*/d;' "$TARGET_DIR/etc/shadow"
#
# which is a hard error on a link whose target does not exist:
#
#     sed: couldn't readlink /var/lib/rasputin/console/shadow
#     make: *** [fs/squashfs/squashfs.mk:47: .../images/rootfs.squashfs] Error 4
#
# main could not build an image on either arch from that commit until this one,
# and NOTHING in CI said so: the checks that cover the console password all
# test the runtime arrangement (a tmpfiles.d line, a helper, a symlink) and
# never touch the build. Only the ~25-minute release build reached squashfs,
# and it does not run on a pull request.
#
# So this test runs the ORDER: it builds a finalized-looking target dir, runs
# post-build.sh over it, runs THE PINNED BUILDROOT'S OWN mkusers over it — not
# a re-implementation of what mkusers does — and then runs post-fakeroot.sh,
# which is where the swap now lives. It fails the way the build fails.
#
# It also pins the second, quieter bug the old placement had: a master copy
# taken before mkusers is missing the shadow row of every package user mkusers
# adds. Here the master is compared against the file mkusers left behind.
#
# And it pins the anti-baked-password guard (F14) at the stage that now owns
# it: root's field must be a lock, or the build fails.
#
# NOT COVERED. That the image boots, that a console login works, and that the
# persistent partition survives an A/B update — only the QEMU smoke and the
# bench can say those. This says the build produces a rootfs whose /etc/shadow
# resolves to the persistent partition and whose master copy ships root locked.
#
# Needs: the pinned Buildroot checkout (./scripts/init-buildroot.sh) and bash 4+
# for Buildroot's own mkusers. Both are present on the CI runner.
#
# Run:   sh test/rootfs-shadow-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
COMMON="$ROOT/board/rasputin/common"
POST_BUILD="$COMMON/post-build.sh"
POST_FAKEROOT="$COMMON/post-fakeroot.sh"
MKUSERS="$ROOT/buildroot/support/scripts/mkusers"

[ -f "$POST_BUILD" ]    || { echo "missing: $POST_BUILD" >&2; exit 2; }
[ -f "$POST_FAKEROOT" ] || { echo "missing: $POST_FAKEROOT" >&2; exit 2; }
if [ ! -f "$MKUSERS" ]; then
	echo "FAIL: $MKUSERS not found." >&2
	echo "      This test runs Buildroot's OWN mkusers, because a copy of it here" >&2
	echo "      would drift from the pin. Run ./scripts/init-buildroot.sh first." >&2
	exit 1
fi
# mkusers is bash, and uses mapfile (bash 4+). macOS ships bash 3.2; a dev box
# without a modern bash gets told so rather than a quiet skip.
if ! bash -c 'declare -f mapfile >/dev/null || type -t mapfile >/dev/null' 2>/dev/null; then
	echo "FAIL: bash with mapfile (bash 4+) is required to run Buildroot's mkusers." >&2
	echo "      Install a modern bash (macOS: brew install bash) or run this on Linux/CI." >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
	# ok <name> <0|1> [detail]
	if [ "$2" = "0" ]; then
		pass=$((pass + 1)); printf '  ok   %s\n' "$1"
	else
		fail=$((fail + 1)); printf '  FAIL %s\n       %s\n' "$1" "${3:-}"
	fi
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
# A refusal: run the script with its output to a log and report 0 when it
# FAILED. (`yes_if ! cmd` cannot work — yes_if runs "$@" as a command and `!`
# is a shell keyword; and redirecting the call itself would swallow the
# helper's own answer into the log.)
refused() { # refused <logfile> <cmd...>
	_log="$1"; shift
	if "$@" >"$_log" 2>&1; then echo 1; else echo 0; fi
	unset _log
}
not_grep() { ! grep -q "$1" "$2"; }

# A target dir as `make target-finalize` leaves one, for the parts that matter
# here: the four account files, with root's field as
# BR2_TARGET_ENABLE_ROOT_LOGIN=n writes it, plus an ordinary system account so
# a dropped row would show. ROOTFIELD lets the guard cases vary it.
make_target() {
	# make_target <dir> [root shadow field]
	_d="$1"
	_rootfield="${2-*}"
	rm -rf "$_d"
	mkdir -p "$_d/etc" "$_d/usr/lib/systemd/system" "$_d/var/lib"
	# post-build.sh also repoints /sbin/init at the machine-id shim, and it
	# REFUSES a tree where /sbin/init is not the systemd symlink or the shim is
	# not there (geekdojo/geekdojo-brain#600) — a guard that exists because a
	# shim exec'ing a path that moved is a kernel panic on the first boot. So a
	# target dir has to carry those three things for post-build to run at all.
	# What the guard does on its own is test/machine-id-test.sh's business.
	mkdir -p "$_d/sbin" "$_d/usr/lib/rasputin/machine-id"
	printf '#!/bin/sh\nexit 0\n' > "$_d/usr/lib/systemd/systemd"
	chmod +x "$_d/usr/lib/systemd/systemd"
	cp "$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/machine-id/rasputin-init" \
		"$_d/usr/lib/rasputin/machine-id/rasputin-init"
	chmod +x "$_d/usr/lib/rasputin/machine-id/rasputin-init"
	ln -s ../lib/systemd/systemd "$_d/sbin/init"
	printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/bin/false\n' \
		> "$_d/etc/passwd"
	printf 'root:%s:20000:0:99999:7:::\nnobody:!:20000:0:99999:7:::\n' "$_rootfield" \
		> "$_d/etc/shadow"
	chmod 600 "$_d/etc/shadow"
	printf 'root:x:0:\nnobody:x:65534:\n' > "$_d/etc/group"
	printf 'root:*::\nnobody:*::\n'       > "$_d/etc/gshadow"
	unset _d _rootfield
}

# Buildroot's mkusers, run the way fs/common.mk runs it: the users table and
# the target dir as arguments, BR2_CONFIG in the environment, stdout captured
# (it is shell, appended to the fakeroot script — not our business here).
run_mkusers() {
	# run_mkusers <target dir>  -> exit status, stderr on stdout
	bash "$MKUSERS" "$TMP/users-table" "$1" 2>&1 >"$TMP/mkusers.fakeroot"
}

cat > "$TMP/br.config" <<'EOF'
BR2_TARGET_GENERIC_PASSWD_METHOD="sha-256"
EOF
BR2_CONFIG="$TMP/br.config"
export BR2_CONFIG

# One package user, the shape Buildroot's own packages declare:
#   username uid group gid passwd home shell groups comment
cat > "$TMP/users-table" <<'EOF'
rasputintest -1 rasputintest -1 ! - /bin/false - Rootfs shadow ordering test
EOF

echo
echo "1. the build's order: post-build, then mkusers, then post-fakeroot"

T="$TMP/target"
make_target "$T"
if ! sh "$POST_BUILD" "$T" n100 >"$TMP/post-build.log" 2>&1; then
	ok "post-build.sh runs against a finalized target dir" 1 "$(cat "$TMP/post-build.log")"
else
	ok "post-build.sh runs against a finalized target dir" 0
fi

# THE REGRESSION. post-build must leave a real /etc/shadow behind: everything
# Buildroot does to the account files after it depends on that.
ok "post-build leaves /etc/shadow a regular file, not a symlink" \
	"$(yes_if test ! -L "$T/etc/shadow")" "$(ls -l "$T/etc/shadow" 2>&1)"
ok "post-build leaves /etc/shadow readable" \
	"$(yes_if test -f "$T/etc/shadow")" "$(ls -l "$T/etc/shadow" 2>&1)"
ok "post-build does not take the master copy early" \
	"$(yes_if test ! -e "$T/usr/share/factory/rasputin/shadow")" \
	"a master taken before mkusers is missing every package user's row"

# THE FAILURE ITSELF. On the broken arrangement this dies with
# "sed: couldn't readlink /var/lib/rasputin/console/shadow".
mkusers_err="$(run_mkusers "$T")"
ok "Buildroot's own mkusers succeeds against the post-build tree" \
	"$(yes_if test -z "$mkusers_err")" "mkusers said: $mkusers_err"
ok "mkusers added its user's row to /etc/shadow" \
	"$(yes_if grep -q '^rasputintest:' "$T/etc/shadow")" "$(cat "$T/etc/shadow" 2>&1)"

# Now the stage that owns the swap.
if ! sh "$POST_FAKEROOT" "$T" n100 >"$TMP/post-fakeroot.log" 2>&1; then
	ok "post-fakeroot.sh runs against the post-mkusers tree" 1 "$(cat "$TMP/post-fakeroot.log")"
else
	ok "post-fakeroot.sh runs against the post-mkusers tree" 0
fi

echo
echo "2. what the rootfs ends up holding"

ok "/etc/shadow is a symlink" \
	"$(yes_if test -L "$T/etc/shadow")" "$(ls -l "$T/etc/shadow" 2>&1)"
ok "/etc/shadow points at the persistent partition" \
	"$(yes_if [ "$(readlink "$T/etc/shadow")" = /var/lib/rasputin/console/shadow ])" \
	"target=$(readlink "$T/etc/shadow" 2>&1)"
# It must dangle IN THE IMAGE — the persistent partition is not mounted at
# build time, and tmpfiles.d seeds the target on first boot. A real file here
# would be a second, stale copy of /etc/shadow inside the read-only rootfs.
ok "the link dangles inside the rootfs (tmpfiles seeds it at first boot)" \
	"$(yes_if test ! -e "$T/var/lib/rasputin/console/shadow")" \
	"$(ls -l "$T/var/lib/rasputin/console" 2>&1)"

MASTER="$T/usr/share/factory/rasputin/shadow"
ok "the factory master exists" "$(yes_if test -f "$MASTER")" "$(ls -l "$T/usr/share/factory/rasputin" 2>&1)"
ok "the factory master is 0600" \
	"$(yes_if [ "$(ls -l "$MASTER" | cut -c2-10)" = 'rw-------' ])" "$(ls -l "$MASTER" 2>&1)"
ok "root is LOCKED in the master — no console password ships" \
	"$(yes_if [ "$(awk -F: '$1=="root"{print $2; exit}' "$MASTER")" = '*' ])" \
	"field=$(awk -F: '$1=="root"{print $2; exit}' "$MASTER")"
# The quieter bug: a master taken before mkusers has no row for any package
# user, so those accounts lose their shadow entry on every node.
ok "the master carries the rows mkusers added" \
	"$(yes_if grep -q '^rasputintest:' "$MASTER")" "$(cat "$MASTER" 2>&1)"
ok "the master carries every other account's row" \
	"$(yes_if grep -q '^nobody:' "$MASTER")" "$(cat "$MASTER" 2>&1)"

echo
echo "3. the guard: no usable root password may be baked (F14)"

# A usable hash in root's field is the regression this guard exists to catch —
# one public password on every downloaded image (geekdojo/geekdojo-brain#546).
guard_case() {
	# guard_case <name> <root field> <expect: refuse|accept>
	_g="$TMP/guard"
	make_target "$_g" "$2"
	sh "$POST_BUILD" "$_g" n100 >/dev/null 2>&1
	run_mkusers "$_g" >/dev/null 2>&1
	if sh "$POST_FAKEROOT" "$_g" n100 >"$TMP/guard.log" 2>&1; then _rc=accept; else _rc=refuse; fi
	ok "$1" "$(yes_if [ "$_rc" = "$3" ])" "got $_rc; script said: $(cat "$TMP/guard.log")"
	if [ "$3" = refuse ]; then
		ok "  ... and left /etc/shadow alone" \
			"$(yes_if test ! -L "$_g/etc/shadow")" "$(ls -l "$_g/etc/shadow" 2>&1)"
	fi
	unset _g _rc
}

guard_case "a locked root (*) is accepted"  '*'  accept
guard_case "a locked root (!) is accepted"  '!'  accept
guard_case "a locked root (!!) is accepted" '!!' accept
guard_case "a baked sha-512 hash is REFUSED" \
	'$6$rounds=100000$abcdefgh$OaYaNCzQ5LMOS2bLSX0Q1WLxbNRJqyqsRwbn3yEQ2t2ThEV5m9JGkRfkxGZ8aBvMLQdKiHVuGYCFFDf0iXo8Y1' \
	refuse
guard_case "a baked DES-era hash is REFUSED" 'ab1234567890X' refuse
guard_case "an EMPTY root field is REFUSED"  ''              refuse

# The message has to name what happened; a build log is all anyone gets.
_g="$TMP/guard"
make_target "$_g" '$6$x$y'
sh "$POST_BUILD" "$_g" n100 >/dev/null 2>&1
sh "$POST_FAKEROOT" "$_g" n100 >"$TMP/guard.log" 2>&1
ok "the refusal names the baked password and cites the story" \
	"$(yes_if grep -q 'usable password baked into the image' "$TMP/guard.log")" "$(cat "$TMP/guard.log")"
ok "the refusal cites geekdojo-brain#546" \
	"$(yes_if grep -q 'geekdojo/geekdojo-brain#546' "$TMP/guard.log")" "$(cat "$TMP/guard.log")"

# Re-running the swap over its own output must refuse, not silently produce a
# rootfs with no master copy at all.
_g="$TMP/rerun"
make_target "$_g"
sh "$POST_BUILD" "$_g" n100 >/dev/null 2>&1
sh "$POST_FAKEROOT" "$_g" n100 >/dev/null 2>&1
ok "a second post-fakeroot run over its own output is REFUSED" \
	"$(refused "$TMP/rerun.log" sh "$POST_FAKEROOT" "$_g" n100)" "$(cat "$TMP/rerun.log")"
ok "  ... naming the lost copy" \
	"$(yes_if grep -q 'already a symlink' "$TMP/rerun.log")" "$(cat "$TMP/rerun.log")"

_g="$TMP/noshadow"
make_target "$_g"
rm -f "$_g/etc/shadow"
ok "a rootfs with no /etc/shadow at all is REFUSED" \
	"$(refused "$TMP/noshadow.log" sh "$POST_FAKEROOT" "$_g" n100)" "$(cat "$TMP/noshadow.log")"

echo
echo "4. the wiring: the hook is actually installed on both SKUs"

# A swap in a script nothing calls is a rootfs that ships a real /etc/shadow on
# the read-only squashfs — no baked password, but no way to ever set one.
ok "post-fakeroot.sh is executable" "$(yes_if test -x "$POST_FAKEROOT")" "$(ls -l "$POST_FAKEROOT")"
for cfg in "$ROOT"/configs/rasputin_*_defconfig; do
	name=$(basename "$cfg")
	ok "$name sets BR2_ROOTFS_POST_FAKEROOT_SCRIPT to post-fakeroot.sh" \
		"$(yes_if grep -qx 'BR2_ROOTFS_POST_FAKEROOT_SCRIPT="$(BR2_EXTERNAL_RASPUTIN_PATH)/board/rasputin/common/post-fakeroot.sh"' "$cfg")" \
		"$(grep -n POST_FAKEROOT "$cfg")"
done
# And post-build must not grow it back.
ok "post-build.sh no longer creates the /etc/shadow symlink" \
	"$(yes_if not_grep 'ln -s /var/lib/rasputin/console/shadow' "$POST_BUILD")" \
	"$(grep -n 'console/shadow' "$POST_BUILD")"

echo
echo "rootfs-shadow: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
