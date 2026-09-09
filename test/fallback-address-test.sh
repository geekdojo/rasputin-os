#!/bin/sh
# Functional tests for rasputin-fallback-address.sh — the controlplane's
# no-DHCP bootstrap address.
#
# Why this is tested at all. The decision it makes is invisible when wrong: a
# fallback that fires on a healthy DHCP network puts a second address on every
# cluster (and into the api leaf's IP SANs — the objection recorded in
# geekdojo-brain #232), and one that DOESN'T fire on a dead network leaves the
# operator staring at an unreachable box with no error anywhere. Neither shows
# up in a build, and neither reproduces in QEMU without a DHCP server to take
# away. So the decision inputs are injectable and pinned here instead.
#
# Everything is faked: a /sys/class/net tree, networkd's lease directory, a
# recording stub for networkctl, and a tmpfs-stand-in for the drop-in. No
# network, no root, no networkd. Runs anywhere.
#
# Run:  sh test/fallback-address-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/netfallback/rasputin-fallback-address.sh"
[ -x "$SCRIPT" ] || { echo "missing or non-executable: $SCRIPT"; exit 1; }

fails=0
check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

# --- a disposable world -------------------------------------------------
# link: name, carrier (1/0), ifindex; lease: "yes" writes networkd's lease file
setup() {
	WORK=$(mktemp -d)
	SYS="$WORK/sys"; LEASES="$WORK/leases"; DROPIN="$WORK/run/20-wired.network.d"
	CALLS="$WORK/networkctl.calls"; NODE_ENV="$WORK/node.env"
	mkdir -p "$SYS/$1" "$LEASES"
	printf '%s\n' "$2" > "$SYS/$1/carrier"
	printf '%s\n' "$3" > "$SYS/$1/ifindex"
	[ "${4:-no}" = "yes" ] && printf 'ADDRESS=192.168.1.117\n' > "$LEASES/$3"
	cat > "$WORK/networkctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NETWORKCTL_CALLS"
STUB
	chmod +x "$WORK/networkctl"
	: > "$CALLS"
	: > "$NODE_ENV"
}
teardown() { rm -rf "$WORK"; }

run() {
	NETWORKCTL_CALLS="$CALLS" \
	RASPUTIN_FALLBACK_SYSCLASS="$SYS" \
	RASPUTIN_FALLBACK_LEASE_DIR="$LEASES" \
	RASPUTIN_FALLBACK_DROPIN_DIR="$DROPIN" \
	RASPUTIN_FALLBACK_NODE_ENV="$NODE_ENV" \
	RASPUTIN_FALLBACK_NETWORKCTL="$WORK/networkctl" \
	sh "$SCRIPT" 2>&1
}

conf() { cat "$DROPIN/50-rasputin-fallback.conf" 2>/dev/null; }
applied() { [ -f "$DROPIN/50-rasputin-fallback.conf" ]; }

# --- 1. DHCP present: stay out of the way -------------------------------
echo "1. a link with a DHCPv4 lease is left alone"
setup enp1s0 1 2 yes
out=$(run)
applied; r=$?
check "writes no drop-in" "$([ $r -ne 0 ] && echo 0 || echo 1)" "$out"
check "says so in the log" "$(echo "$out" | grep -q 'leaving addressing to DHCP' && echo 0 || echo 1)" "$out"
check "does not touch networkd" "$([ ! -s "$CALLS" ] && echo 0 || echo 1)" "$(cat "$CALLS")"
teardown

# --- 2. no DHCP: take the address ---------------------------------------
echo "2. a link with no lease gets the fallback address"
setup enp1s0 1 2 no
out=$(run)
applied; r=$?
check "writes the drop-in" "$r" "$out"
check "address is 192.168.1.2/24" "$(conf | grep -q '^Address=192\.168\.1\.2/24$' && echo 0 || echo 1)" "$(conf)"
check "reloads and reconfigures the link" \
	"$(grep -q '^reload$' "$CALLS" && grep -q '^reconfigure enp1s0$' "$CALLS" && echo 0 || echo 1)" "$(cat "$CALLS")"

# The two properties the design turns on, guarded so a later edit can't quietly
# drop them: no default route to a gateway that does not exist yet, and a
# drop-in that a reboot removes (tmpfs) so DHCP resumes ownership by itself.
check "sets NO Gateway= (the .1 firewall does not exist yet)" \
	"$(conf | grep -qi '^Gateway=' && echo 1 || echo 0)" "$(conf)"
check "drop-in is under the runtime dir, not /etc" \
	"$(echo "$DROPIN" | grep -q '/run/' && echo 0 || echo 1)" "$DROPIN"
teardown

# --- 3. no carrier: nothing to address ----------------------------------
echo "3. an unplugged link is not the uplink"
setup enp1s0 0 2 no
out=$(run)
applied; r=$?
check "writes no drop-in" "$([ $r -ne 0 ] && echo 0 || echo 1)" "$out"
check "says why" "$(echo "$out" | grep -q 'no wired link with carrier' && echo 0 || echo 1)" "$out"
teardown

# --- 4. the seed can override the address -------------------------------
echo "4. RASPUTIN_FALLBACK_ADDRESS from node.env wins"
setup enp1s0 1 2 no
printf 'RASPUTIN_FALLBACK_ADDRESS=10.10.0.2/16\n' > "$NODE_ENV"
out=$(run)
check "uses the override" "$(conf | grep -q '^Address=10\.10\.0\.2/16$' && echo 0 || echo 1)" "$(conf)"
teardown

echo "5. an empty override is an explicit opt-out"
setup enp1s0 1 2 no
printf 'RASPUTIN_FALLBACK_ADDRESS=\n' > "$NODE_ENV"
out=$(run)
applied; r=$?
check "writes no drop-in" "$([ $r -ne 0 ] && echo 0 || echo 1)" "$out"
check "says it was disabled" "$(echo "$out" | grep -q 'disabled by configuration' && echo 0 || echo 1)" "$out"
teardown

echo "6. a malformed override is refused, not half-applied"
for bad in 'not-an-address/24' '192.168.1.2' '192.168.1.2/xx'; do
	setup enp1s0 1 2 no
	printf 'RASPUTIN_FALLBACK_ADDRESS=%s\n' "$bad" > "$NODE_ENV"
	out=$(run)
	applied; r=$?
	check "refuses '$bad'" "$([ $r -ne 0 ] && echo 0 || echo 1)" "$out"
	teardown
done

# --- 7. the unit's own gating -------------------------------------------
echo "7. the unit is controlplane-gated and ordered on facts, not a timer"
UNIT="$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/system/rasputin-fallback-address.service"
check "ConditionPathExists=/var/lib/rasputin/role.controlplane" \
	"$(grep -q '^ConditionPathExists=/var/lib/rasputin/role\.controlplane$' "$UNIT" && echo 0 || echo 1)"
check "runs after network-online.target" \
	"$(grep -q '^After=.*network-online\.target' "$UNIT" && echo 0 || echo 1)"
check "runs before the console IP banner" \
	"$(grep -q '^Before=.*rasputin-issue-ip\.service' "$UNIT" && echo 0 || echo 1)"
check "enabled in post-build.sh" \
	"$(grep -q 'rasputin-fallback-address\.service' "$ROOT/board/rasputin/common/post-build.sh" && echo 0 || echo 1)"

# --- 8. the seed override actually reaches node.env ---------------------
# firstboot writes a CURATED key set, so a key the seed carries but firstboot
# does not copy is silently inert -- exactly how the control plane's Add-Node
# wizard lost RASPUTIN_CLUSTER_ID (control-plane #71). Guard both the copy and
# its set-but-empty semantics.
echo "8. firstboot passes the override through to node.env"
FB="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin/firstboot/rasputin-firstboot.sh"
check "reads RASPUTIN_FALLBACK_ADDRESS from the seed" \
	"$(grep -q 'RASPUTIN_FALLBACK_ADDRESS+set' "$FB" && echo 0 || echo 1)"
check "writes it into node.env" \
	"$(grep -q 'echo "RASPUTIN_FALLBACK_ADDRESS=' "$FB" && echo 0 || echo 1)"
check "distinguishes set-but-empty from unset (opt-out survives)" \
	"$(grep -q 'FALLBACK_ADDRESS_SET' "$FB" && echo 0 || echo 1)"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all fallback-address tests passed"
