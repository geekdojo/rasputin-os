#!/bin/sh
#
# memory-floor.sh FLOOR_FILE ROOTFS_IMG...
#
# Prints the JSON object release.yml merges into manifest.json: the control
# plane's memory floor, and whether the release carries the identity service
# (geekdojo/geekdojo-brain#1011).
#
#   {"controlPlaneMemoryFloorBytes":N}
#   {"controlPlaneMemoryFloorBytes":N,"identityService":true}
#
# FLOOR_FILE (the repo's memory-floor-mib.txt) holds one positive decimal
# integer of MiB: the support minimum for a control plane, stated as the
# memory the board reports. It is emitted in bytes. A control plane refuses a
# fleet update whose release states a floor its own memory is below, and
# refuses an identity release that states none, so every release states one:
# an absent, empty, zero, signed, fractional, non-numeric or multi-line value
# is refused here, before anything is signed.
#
# identityService is read from the built images, not set by hand: it is true
# when any ROOTFS_IMG lists a keycloak.service unit in etc/systemd/system/ or
# usr/lib/systemd/system/. A keycloak-db.service, the keycloak.service.d/
# drop-in directory and anything inside it do not count. A rootfs unsquashfs
# cannot list (missing, unreadable, not a squashfs) is refused, because then
# nobody can tell whether the identity service is in it.
#
# Exit status:
#   0  the JSON object is printed on stdout
#   1  the floor or a rootfs is refused (one ::error:: line on stderr naming
#      the file, nothing on stdout)
#   2  usage error
#
# test/memory-floor-test.sh covers every status.
set -eu

fail() {
	_status=$1
	shift
	printf '::error::memory-floor: %s\n' "$*" >&2
	exit "$_status"
}

[ "$#" -ge 2 ] || fail 2 "usage: memory-floor.sh FLOOR_FILE ROOTFS_IMG..."
file=$1
shift

[ -f "$file" ] || fail 1 "$file: the floor file is missing; every release states the control plane's memory floor in MiB"
[ -r "$file" ] || fail 1 "$file: the floor file cannot be read"
# $(cat) drops the trailing newline an editor leaves; anything else on another
# line is part of the value, so it fails the one-line check below.
mib=$(cat "$file")
[ "$(printf '%s\n' "$mib" | wc -l | tr -d ' ')" = 1 ] \
	|| fail 1 "$file: the floor must be one line holding a positive whole number of MiB"
printf '%s\n' "$mib" | grep -Eqx '[1-9][0-9]*' \
	|| fail 1 "$file: floor '$mib' is not a positive whole number of MiB"
bytes=$((mib * 1048576))

identity=false
for img in "$@"; do
	[ -f "$img" ] || fail 1 "$img: the rootfs image is missing, so whether it carries the identity service cannot be told"
	if ! listing=$(unsquashfs -l "$img" 2>/dev/null); then
		fail 1 "$img: unsquashfs could not list the rootfs image (unreadable or not a squashfs), so whether it carries the identity service cannot be told"
	fi
	if printf '%s\n' "$listing" | grep -Eq '(^|/)(etc|usr/lib)/systemd/system/keycloak\.service$'; then
		identity=true
	fi
done

if [ "$identity" = true ]; then
	printf '{"controlPlaneMemoryFloorBytes":%s,"identityService":true}\n' "$bytes"
else
	printf '{"controlPlaneMemoryFloorBytes":%s}\n' "$bytes"
fi
