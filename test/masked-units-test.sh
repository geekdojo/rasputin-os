#!/bin/sh
# Assertions on the stock systemd units this image masks.
#
# Why masking is tested at all. A mask is a symlink to /dev/null, and a symlink
# is the easiest thing in the overlay to lose: a rebase, a copy that resolves
# links, a tool that rewrites the tree. Nothing about the resulting image looks
# different, and the unit it un-masks fails quietly during boot. What that costs
# is stated per-unit below.
#
# This is a static assertion on the rootfs overlay, not a functional test — it
# reads what ships. Proving the unit is actually inert needs an image build and
# a boot, which is a separate exercise. No root, no systemd, runs anywhere.
#
# Run:  sh test/masked-units-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SYSD="$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/system"
[ -d "$SYSD" ] || { echo "missing: $SYSD" >&2; exit 2; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# masked UNIT — /etc/systemd/system/<unit> is a symlink to /dev/null, which is
# how systemd is told a unit cannot be started. A regular file there would be a
# unit OVERRIDE, not a mask, and an empty one is a unit with no directives that
# starts perfectly happily: hence the -L test rather than a -e.
masked() {
	_u="$SYSD/$1"
	[ -L "$_u" ] || { printf 'not a symlink (a plain file is an override, not a mask)'; return 1; }
	_t=$(readlink "$_u")
	[ "$_t" = "/dev/null" ] || { printf 'points at %s, not /dev/null' "$_t"; return 1; }
	return 0
}

# systemd-networkd-persistent-storage.service exists to hand networkd a writable
# directory to remember DHCP leases in. /var/lib is a read-only squashfs by
# design, so `networkctl persistent-storage yes` answers
# io.systemd.Network.StorageReadOnly and the unit fails on every boot of every
# node — meaning `systemctl --failed` is never empty on an appliance, which is
# the one place a real failure would have to show itself to be noticed.
#
# Masking is safe in this direction and the direction matters: the unit declares
# BindsTo=systemd-networkd.service (it depends on networkd), while networkd
# names it only in Wants= — never Requires=, Requisite= or BindsTo=. A masked
# Wants= is skipped silently, so networkd is unaffected.
echo "1. systemd-networkd-persistent-storage.service is masked"
out=$(masked systemd-networkd-persistent-storage.service) && r=0 || r=1
check "masked with a /dev/null symlink in the overlay" "$r" "$out"

# The lease memory it would have provided is delivered instead by
# ClientIdentifier=mac in 20-wired.network: the address is stable because the
# DHCP server keys it on the MAC, so nothing has to be remembered on the node.
# If that setting ever goes away this mask stops being free, so the two are
# pinned to each other here rather than only in a commit message.
check "its purpose is covered by ClientIdentifier=mac (nothing to remember)" \
	"$(grep -qx 'ClientIdentifier=mac' \
		"$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/network/20-wired.network" \
		&& echo 0 || echo 1)" \
	"ClientIdentifier=mac is gone from 20-wired.network — the node now has no stable address AND no lease memory"

# postgresql.service is Buildroot's own unit, installed by the carried
# PostgreSQL (package/rasputin-postgresql, geekdojo/geekdojo-brain#972). It has
# WantedBy=multi-user.target and runs initdb into /var/lib/pgsql, so unmasked,
# preset-all enables it and every node starts a database nobody configured, on
# a path the read-only rootfs cannot hold, with the stock settings rather than
# the identity database's TLS-only ones. The identity units own when and where
# PostgreSQL runs; this mask is what keeps Buildroot's unit out of the way.
echo
echo "2. postgresql.service is masked (TC-972-02)"
out=$(masked postgresql.service) && r=0 || r=1
check "TC-972-02 masked with a /dev/null symlink in the overlay" "$r" "$out"

# Negative controls: the two ways the mask can be lost must each fail with the
# sentence that says which.
starts_with() { case "$2" in "$1"*) echo 0 ;; *) echo 1 ;; esac; }
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT
REAL_SYSD="$SYSD"
SYSD="$SCRATCH"
: > "$SYSD/postgresql.service"
out=$(masked postgresql.service) && r=0 || r=1
check "TC-972-02 a regular empty file is refused" "$([ "$r" = 1 ] && echo 0 || echo 1)" "masked() accepted a plain file"
check "TC-972-02 ... saying it is not a symlink" \
	"$(starts_with "not a symlink" "$out")" "said: $out"
rm -f "$SYSD/postgresql.service"
ln -s /usr/lib/systemd/system/postgresql.service "$SYSD/postgresql.service"
out=$(masked postgresql.service) && r=0 || r=1
check "TC-972-02 a symlink elsewhere is refused" "$([ "$r" = 1 ] && echo 0 || echo 1)" "masked() accepted a link to the real unit"
check "TC-972-02 ... saying where it points" \
	"$(starts_with "points at /usr/lib/systemd/system/postgresql.service," "$out")" "said: $out"
SYSD="$REAL_SYSD"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all masked-units tests passed"
