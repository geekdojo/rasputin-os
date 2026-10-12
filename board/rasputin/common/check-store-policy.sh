#!/bin/sh
#
# check-store-policy.sh — refuse an image whose secrets store would fail its
# first start for want of its policy text (geekdojo/geekdojo-brain#804;
# ADR-0010 S9). post-build.sh runs it.
#
# Usage: board/rasputin/common/check-store-policy.sh TARGET_DIR BUILD_SRC
#
#   TARGET_DIR  the assembled rootfs
#   BUILD_SRC   the extracted rasputin-api tarball (Buildroot's
#               $(BUILD_DIR)/rasputin-api-<version>)
#
# WHY. The store's self-init reads each policy from a `file` source that
# init.json names. A file that cannot be read fails self-init after its marker,
# and that store refuses to unseal on every later start (#680 Q1, Q8). So the
# build stops when:
#   - init.json is missing, or names no policy file under
#     /usr/share/rasputin/openbao-policy/;
#   - a policy file init.json names is absent or empty in TARGET_DIR;
#   - the image's openbao-policy/ differs from the tarball's
#     (scripts/store-policy-drift.sh), which is the text
#     rasputin-control-plane's tests ran.
#
# Exit status: 0 the image carries its policy text; 1 it does not (each
# reason a sentence on stderr); 2 bad usage.
set -u

if [ "$#" -ne 2 ] || [ -z "$1" ] || [ -z "$2" ]; then
	echo "Usage: $0 TARGET_DIR BUILD_SRC, the assembled rootfs and the extracted rasputin-api tarball." >&2
	exit 2
fi
TARGET=$1 SRC=$2
POLICY_DIR=/usr/share/rasputin/openbao-policy
INIT=/etc/rasputin/openbao/init.json
DRIFT="$(dirname "$0")/../../../scripts/store-policy-drift.sh"

die() { echo "check-store-policy: $1" >&2; exit 1; }

[ -f "$TARGET$INIT" ] || die "The store's self-init config $TARGET$INIT is missing, so the image cannot say which policy files its store reads."
# Every file source path under the policy directory, one per line. init.json
# is the overlay's own JSON, one key per line; test/store-config-test.sh holds
# every file source to this directory or the store CA's credential.
named=$(sed -n 's|.*"path"[[:space:]]*:[[:space:]]*"\('"$POLICY_DIR"'/[^"]*\)".*|\1|p' "$TARGET$INIT" | LC_ALL=C sort -u)
[ -n "$named" ] || die "The store's self-init config $TARGET$INIT names no policy file under $POLICY_DIR, so the store would initialise with no policy."
bad=0
while IFS= read -r p; do
	if [ ! -f "$TARGET$p" ]; then
		echo "check-store-policy: The policy file $p that init.json names is not in the image, so the store's first start would fail and it would never unseal." >&2
		bad=1
	elif [ ! -s "$TARGET$p" ]; then
		echo "check-store-policy: The policy file $p that init.json names is empty in the image, so the store would initialise with a policy that grants nothing." >&2
		bad=1
	fi
done <<-EOF2
$named
EOF2
[ "$bad" -eq 0 ] || exit 1

if ! sh "$DRIFT" "$TARGET$POLICY_DIR" "$SRC/openbao-policy"; then
	die "The image's policy text in $POLICY_DIR is not the rasputin-api tarball's ($SRC/openbao-policy), so the store would enforce text that rasputin-control-plane did not test."
fi
echo "check-store-policy: the image carries every policy file init.json names, byte-equal to the rasputin-api tarball's."
