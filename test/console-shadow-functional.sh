#!/bin/sh
# Functional test for the console root password's arrangement on this image,
# against REAL systemd-tmpfiles 256.17 — the version Buildroot 2025.02.17
# builds into the image — and the real tmpfiles.d line and helper from the
# rootfs overlay. geekdojo/geekdojo-brain#546.
#
# WHY THIS EXISTS. The whole arrangement is configuration plus one line of
# tmpfiles.d, and the claim it rests on is a claim about what systemd does:
#
#   C /var/lib/rasputin/console/shadow 0600 root root - /usr/share/factory/rasputin/shadow
#
# "C copies the master in only when the destination does not exist, and applies
# the mode" is a reading of a manual page. If it is wrong in either direction
# the failure is silent and serious. Wrong one way, every boot overwrites the
# shadow file and a delivered root password is reverted on the next reboot —
# the operator sets a console password, it works, and then it does not. Wrong
# the other way, the file is created at whatever umask systemd happened to
# have, and /etc/shadow — the file holding every account's hash — is
# world-readable on every node.
#
# Nothing in a build or a shell check can show which it is, so this runs the
# real line through the real systemd and looks.
#
# Scenarios, all in one container:
#   1  a fresh node: tmpfiles creates the directory 0700 and copies the master
#      shadow in at 0600 root:root, with root LOCKED (no console password)
#   2  a reboot: a second run leaves a DELIVERED hash exactly as it was
#   3  a widened mode on the file is tightened by the next run
#   4  the whole path end to end: /etc/shadow as the baked-in symlink, the
#      helper invoked the way the agent invokes it (hash on stdin), and the
#      hash landing in the resolved file on the persistent partition
#   5  the read-only-rootfs shape: with the directory holding the LINK
#      read-only, the helper still succeeds — which is the case a scratch-file
#      test cannot see, and the one that fails with EROFS on a real node if
#      the temp file is written beside the link instead of beside the target
#
# NOT COVERED, and only the bench can cover it: an actual console login with
# the delivered password, and an A/B update preserving the partition. This
# covers the file, its mode, and who writes it.
#
# Needs: docker. Linux runner or Docker Desktop.
# Run:   sh test/console-shadow-functional.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
IMAGE=rasputin-console-shadow-functional:f41-systemd-256.17

command -v docker >/dev/null 2>&1 || { echo "docker not found - this test needs docker"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }

# Fedora 41 ships systemd 256.17, the same release as the image, so what
# systemd-tmpfiles does with this line here is what it does on a node.
echo "building test image ($IMAGE)"
docker build -q -t "$IMAGE" - >/dev/null <<'DOCKERFILE' || { echo "FAILED: could not build the test image"; exit 1; }
FROM fedora:41
RUN dnf -y install --setopt=install_weak_deps=False systemd-256.17 util-linux findutils \
 && dnf clean all
DOCKERFILE

CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; CID=""; }
trap cleanup EXIT INT TERM

# No init needed: systemd-tmpfiles is run directly, which is exactly what
# systemd-tmpfiles-setup.service does on a node.
CID=$(docker run -d --privileged --tmpfs /run --tmpfs /tmp \
	-v "$OVERLAY:/overlay:ro" "$IMAGE" sleep 900) \
	|| { echo "FAILED: could not start container"; exit 1; }
inside() { docker exec "$CID" sh -c "$*"; }
echo "in the container: $(inside 'systemd-tmpfiles --version | head -1')"

# The master copy the build produces: root LOCKED, exactly what
# BR2_TARGET_ENABLE_ROOT_LOGIN=n writes into the rootfs.
inside 'mkdir -p /usr/share/factory/rasputin && \
	printf "root:*:20000:0:99999:7:::\nnobody:!:20000:0:99999:7:::\n" > /usr/share/factory/rasputin/shadow && \
	chmod 600 /usr/share/factory/rasputin/shadow' >/dev/null

# The image's own tmpfiles.d, as shipped. Only the console lines are exercised;
# the rest of the file is harmless here and running it whole is the point —
# this is the file a node runs.
inside 'mkdir -p /usr/lib/tmpfiles.d && cp /overlay/usr/lib/tmpfiles.d/rasputin.conf /usr/lib/tmpfiles.d/rasputin.conf' >/dev/null
inside 'cp /overlay/usr/lib/rasputin/set-root-hash /usr/local/bin/set-root-hash && chmod 755 /usr/local/bin/set-root-hash' >/dev/null

tmpfiles() { inside 'systemd-tmpfiles --create /usr/lib/tmpfiles.d/rasputin.conf 2>&1 | grep -v "Failed to replace specifiers" || true' >/dev/null 2>&1; }
mode() { inside "stat -c %a '$1' 2>/dev/null"; }
owner() { inside "stat -c %U:%G '$1' 2>/dev/null"; }
rootfield() { inside "awk -F: '\$1==\"root\"{print \$2; exit}' '$1' 2>/dev/null"; }

SHADOW=/var/lib/rasputin/console/shadow

# /etc/shadow as the image bakes it: a symlink onto the persistent partition
# (post-build.sh). Put in place BEFORE anything runs, so every invocation
# below takes the path a node takes — the helper's default is /etc/shadow, and
# a test that quietly wrote to the container's own file would prove nothing.
inside "rm -f /etc/shadow && ln -s $SHADOW /etc/shadow" >/dev/null

echo
echo "1. a fresh node: the directory and the master copy"
tmpfiles
check "the console directory exists" "$(yes_if inside 'test -d /var/lib/rasputin/console')"
check "the console directory is 0700" "$(yes_if [ "$(mode /var/lib/rasputin/console)" = 700 ])" "mode=$(mode /var/lib/rasputin/console)"
check "the shadow file was copied in" "$(yes_if inside "test -f $SHADOW")"
check "the shadow file is 0600" "$(yes_if [ "$(mode $SHADOW)" = 600 ])" "mode=$(mode $SHADOW)"
check "the shadow file is root:root" "$(yes_if [ "$(owner $SHADOW)" = root:root ])" "owner=$(owner $SHADOW)"
check "root ships LOCKED — no console password" "$(yes_if [ "$(rootfield $SHADOW)" = '*' ])" "field=$(rootfield $SHADOW)"

echo
echo "2. a reboot must not revert a delivered password"
DELIVERED='$6$rounds=100000$abcdefgh$OaYaNCzQ5LMOS2bLSX0Q1WLxbNRJqyqsRwbn3yEQ2t2ThEV5m9JGkRfkxGZ8aBvMLQdKiHVuGYCFFDf0iXo8Y1'
inside "printf '%s' '$DELIVERED' | set-root-hash" >/dev/null 2>&1
check "the delivered hash is in place" "$(yes_if [ "$(rootfield $SHADOW)" = "$DELIVERED" ])" "field=$(rootfield $SHADOW)"
tmpfiles
check "a second tmpfiles run leaves the delivered hash alone" \
	"$(yes_if [ "$(rootfield $SHADOW)" = "$DELIVERED" ])" "field after re-run=$(rootfield $SHADOW)"

echo
echo "3. a widened mode is tightened by the next run"
inside "chmod 644 $SHADOW" >/dev/null
tmpfiles
check "a 0644 shadow is brought back to 0600" "$(yes_if [ "$(mode $SHADOW)" = 600 ])" "mode=$(mode $SHADOW)"
check "tightening the mode did not revert the hash" \
	"$(yes_if [ "$(rootfield $SHADOW)" = "$DELIVERED" ])" "field=$(rootfield $SHADOW)"

echo
echo "4. end to end through the baked-in /etc/shadow symlink"
OTHER='$6$rounds=100000$hgfedcba$1YbLQXRZ8dGdlBYtPqTLtFvxJvKGKVbqHkCJ9JzT8PvJHmVjMRZgGfkC5dQ0nTWsKcYbVJHhEqGJx0aZqRXm81'
inside "printf '%s' '$OTHER' | set-root-hash" >/dev/null 2>&1
check "the helper follows /etc/shadow to the persistent file" \
	"$(yes_if [ "$(rootfield $SHADOW)" = "$OTHER" ])" "field=$(rootfield $SHADOW)"
check "/etc/shadow is still a symlink" "$(yes_if inside 'test -L /etc/shadow')" "$(inside 'ls -l /etc/shadow')"
check "no temp file was left in /etc" \
	"$(yes_if inside '[ -z "$(find /etc -maxdepth 1 -name "*.rasputin.*" 2>/dev/null)" ]')" "$(inside 'ls -a /etc | grep rasputin || true')"
check "no temp file was left beside the target" \
	"$(yes_if inside '[ -z "$(find /var/lib/rasputin/console -name "*.rasputin.*" 2>/dev/null)" ]')" "$(inside 'ls -a /var/lib/rasputin/console')"
check "the file is still 0600 after the helper wrote it" \
	"$(yes_if [ "$(mode $SHADOW)" = 600 ])" "mode=$(mode $SHADOW)"
check "every other row survived" \
	"$(yes_if inside "grep -qx 'nobody:!:20000:0:99999:7:::' $SHADOW")" "$(inside "cat $SHADOW")"

echo
echo "5. the read-only-rootfs shape: the directory holding the LINK is read-only"
# This is the case the scratch-file tests cannot see. On a node /etc is a
# read-only squashfs, so a temp file written beside /etc/shadow fails with
# EROFS and the push reports a node that cannot take a password — which is
# exactly the state this story exists to leave behind.
inside 'mkdir -p /ro/etc && ln -sf /var/lib/rasputin/console/shadow /ro/etc/shadow && mount -o bind,ro /ro /mnt' >/dev/null 2>&1
THIRD='$6$rounds=100000$zyxwvuts$2ZcMRYSA9eHemCZuQrUMuGwyKwLHLWcrIlDKAKaU9QwKInWkNSAhHglD6eR1oUXtLdZcWKIiFrHKy1bArSYn92'
rc=$(inside "printf '%s' '$THIRD' | RASPUTIN_SHADOW_FILE=/mnt/etc/shadow set-root-hash >/dev/null 2>&1; echo \$?")
check "the helper succeeds through a link on a read-only filesystem" "$(yes_if [ "$rc" = 0 ])" "exit=$rc"
check "the hash landed in the writable target" \
	"$(yes_if [ "$(rootfield $SHADOW)" = "$THIRD" ])" "field=$(rootfield $SHADOW)"

echo
if [ "$fails" -eq 0 ]; then
	echo "console-shadow-functional: all checks passed"
else
	echo "console-shadow-functional: $fails check(s) FAILED"
fi
[ "$fails" -eq 0 ]
