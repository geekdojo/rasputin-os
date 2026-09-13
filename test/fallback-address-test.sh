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
#
# The stubs model just enough of networkd and the kernel to check the property
# #427 is about -- how many addresses the link ends up with:
#   $ADDRS            one "dev address" line per address the kernel holds
#   networkctl reload applies the drop-in's Address= to the link, or, when the
#                     drop-in is gone, drops the address it last applied (what
#                     networkd does when a reload finds the config changed)
#   ip                answers `-4 -o addr show dev X` and `addr del A dev X`
#   systemctl, flock  record / no-op, so nothing touches the host's systemd
setup() {
	WORK=$(mktemp -d)
	SYS="$WORK/sys"; LEASES="$WORK/leases"; DROPIN="$WORK/run/20-wired.network.d"
	CALLS="$WORK/networkctl.calls"; NODE_ENV="$WORK/node.env"
	STATE="$WORK/run/rasputin/fallback-address"; ADDRS="$WORK/addrs"
	SYSTEMCTL_CALLS="$WORK/systemctl.calls"; IP_CALLS="$WORK/ip.calls"
	mkdir -p "$SYS/$1" "$LEASES"
	printf '%s\n' "$2" > "$SYS/$1/carrier"
	printf '%s\n' "$3" > "$SYS/$1/ifindex"
	FAKE_LINK="$1"
	: > "$ADDRS"
	[ "${4:-no}" = "yes" ] && lease "$3"
	cat > "$WORK/networkctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$NETWORKCTL_CALLS"
[ "${NETWORKCTL_FAIL:-}" = "$1" ] && exit 1
if [ "$1" = reload ]; then
	f="$FAKE_DROPIN/50-rasputin-fallback.conf"
	if [ -f "$f" ]; then
		a=$(sed -n 's/^Address=//p' "$f")
		grep -qxF "$FAKE_LINK $a" "$FAKE_ADDRS" || printf '%s %s\n' "$FAKE_LINK" "$a" >> "$FAKE_ADDRS"
		printf '%s\n' "$a" > "$FAKE_ADDRS.applied"
	elif [ -f "$FAKE_ADDRS.applied" ]; then
		a=$(cat "$FAKE_ADDRS.applied")
		grep -vxF "$FAKE_LINK $a" "$FAKE_ADDRS" > "$FAKE_ADDRS.tmp"; mv "$FAKE_ADDRS.tmp" "$FAKE_ADDRS"
		rm -f "$FAKE_ADDRS.applied"
	fi
fi
exit 0
STUB
	cat > "$WORK/ip" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$IP_CALLS"
case "$*" in
	"-4 -o addr show dev "*)
		dev=$6
		grep "^$dev " "$FAKE_ADDRS" | while read -r d a; do
			printf '2: %s    inet %s scope global %s\\       valid_lft forever preferred_lft forever\n' "$d" "$a" "$d"
		done ;;
	"addr del "*)
		a=$3; dev=$5
		grep -qxF "$dev $a" "$FAKE_ADDRS" || { echo "RTNETLINK answers: Cannot assign requested address" >&2; exit 2; }
		grep -vxF "$dev $a" "$FAKE_ADDRS" > "$FAKE_ADDRS.tmp"; mv "$FAKE_ADDRS.tmp" "$FAKE_ADDRS" ;;
	*) echo "ip stub: unexpected: $*" >&2; exit 99 ;;
esac
STUB
	cat > "$WORK/systemctl" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_CALLS"
STUB
	printf '#!/bin/sh\nexit 0\n' > "$WORK/flock"
	chmod +x "$WORK/networkctl" "$WORK/ip" "$WORK/systemctl" "$WORK/flock"
	: > "$CALLS"; : > "$SYSTEMCTL_CALLS"; : > "$IP_CALLS"
	: > "$NODE_ENV"
}
teardown() { rm -rf "$WORK"; }

# networkd acquires a DHCPv4 lease on ifindex $1: the lease file, and (when a
# second arg is given) the address it brings on the fake link.
lease() {
	printf 'ADDRESS=%s\n' "${2:-192.168.1.117}" > "$LEASES/$1"
	[ -n "${2:-}" ] && printf '%s %s/24\n' "$FAKE_LINK" "$2" >> "$ADDRS"
	return 0
}

run() {
	NETWORKCTL_CALLS="$CALLS" SYSTEMCTL_CALLS="$SYSTEMCTL_CALLS" IP_CALLS="$IP_CALLS" \
	FAKE_DROPIN="$DROPIN" FAKE_ADDRS="$ADDRS" FAKE_LINK="$FAKE_LINK" \
	RASPUTIN_FALLBACK_SYSCLASS="$SYS" \
	RASPUTIN_FALLBACK_LEASE_DIR="$LEASES" \
	RASPUTIN_FALLBACK_DROPIN_DIR="$DROPIN" \
	RASPUTIN_FALLBACK_STATE_DIR="$STATE" \
	RASPUTIN_FALLBACK_NODE_ENV="$NODE_ENV" \
	RASPUTIN_FALLBACK_NETWORKCTL="$WORK/networkctl" \
	RASPUTIN_FALLBACK_IP="$WORK/ip" \
	RASPUTIN_FALLBACK_SYSTEMCTL="$WORK/systemctl" \
	RASPUTIN_FALLBACK_FLOCK="$WORK/flock" \
	sh "$SCRIPT" "$@" 2>&1
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
check "requires the persistent mount the role gate lives on" \
	"$(grep -q '^RequiresMountsFor=/var/lib/rasputin$' "$UNIT" && echo 0 || echo 1)"
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

# --- 9. the release: a lease makes the fallback go (geekdojo-brain#427) ---
count() { grep -c . "$ADDRS"; }
has_addr() { grep -qxF "$FAKE_LINK $1" "$ADDRS"; }

echo "9. the #427 race: a lease that arrives after the boot decision"
setup end0 1 2 no
out=$(run)
check "no lease at boot: the fallback is applied" "$(has_addr 192.168.1.2/24 && echo 0 || echo 1)" "$out"
check "boot decision re-arms the release unit" \
	"$(grep -qxF -- '--no-block stop rasputin-fallback-address-release.service' "$SYSTEMCTL_CALLS" && echo 0 || echo 1)" "$(cat "$SYSTEMCTL_CALLS")"
# 0.4 s later networkd gets its lease -- the order the bench saw, twice.
lease 2 192.168.1.224
check "precondition: both addresses up, as observed on the bench" "$([ "$(count)" = 2 ] && echo 0 || echo 1)" "$(cat "$ADDRS")"
run lease-held >/dev/null; r=$?
check "lease-held says yes (ExecCondition passes)" "$r"
: > "$CALLS"
out=$(run release); r=$?
check "release succeeds" "$r" "$out"
check "exactly one address remains" "$([ "$(count)" = 1 ] && echo 0 || echo 1)" "$(cat "$ADDRS")"
check "and it is the DHCP one" "$(has_addr 192.168.1.224/24 && echo 0 || echo 1)" "$(cat "$ADDRS")"
check "the drop-in is gone, so networkd cannot re-add it" "$(applied && echo 1 || echo 0)" "$(conf)"
check "removes the address from the link directly" \
	"$(grep -qxF 'addr del 192.168.1.2/24 dev end0' "$IP_CALLS" && echo 0 || echo 1)" "$(cat "$IP_CALLS")"
check "reloads networkd so its in-memory config drops it too" "$(grep -qx 'reload' "$CALLS" && echo 0 || echo 1)" "$(cat "$CALLS")"
check "does NOT reconfigure the link (the reload already does)" "$(grep -q '^reconfigure' "$CALLS" && echo 1 || echo 0)" "$(cat "$CALLS")"
check "leaves no reload-pending marker" "$([ ! -e "$STATE/reload-pending" ] && echo 0 || echo 1)"
out=$(run release); r=$?
check "a second release is a quiet no-op" "$([ $r -eq 0 ] && [ "$(count)" = 1 ] && echo 0 || echo 1)" "$out"
teardown

echo "10. a box that never applied the fallback is left alone by the release"
setup end0 1 2 yes
lease 2 192.168.1.224
out=$(run release); r=$?
check "exits 0" "$r" "$out"
check "does not touch networkd" "$([ ! -s "$CALLS" ] && echo 0 || echo 1)" "$(cat "$CALLS")"
check "does not touch addresses" "$([ ! -s "$IP_CALLS" ] && [ "$(count)" = 1 ] && echo 0 || echo 1)" "$(cat "$IP_CALLS")"
teardown

echo "11. lease-held: the fact, and only the fact"
setup end0 1 2 no
run lease-held >/dev/null; r=$?
check "no lease file -> 1 (the release unit is skipped, not latched)" "$([ $r -eq 1 ] && echo 0 || echo 1)"
# networkd writes a lease as a dot-prefixed temp file renamed into place.
printf 'ADDRESS=192.168.1.224\n' > "$LEASES/.#2AbCdEf"
run lease-held >/dev/null; r=$?
check "networkd's in-flight temp file is not a lease" "$([ $r -eq 1 ] && echo 0 || echo 1)"
out=$(run)
check "...and does not stop the fallback being applied" "$(applied && echo 0 || echo 1)" "$out"
teardown

echo "12. a lease on another wired link also counts"
setup end0 1 2 no
mkdir -p "$SYS/end1"; echo 1 > "$SYS/end1/carrier"; echo 3 > "$SYS/end1/ifindex"
lease 3
out=$(run)
check "apply refuses" "$(applied && echo 1 || echo 0)" "$out"
check "and does not touch networkd" "$([ ! -s "$CALLS" ] && echo 0 || echo 1)" "$(cat "$CALLS")"
teardown

echo "13. a release interrupted before its reload finishes the job next time"
setup end0 1 2 no
run >/dev/null
lease 2 192.168.1.224
out=$(NETWORKCTL_FAIL=reload run release); r=$?
check "a failed reload fails the unit" "$([ $r -ne 0 ] && echo 0 || echo 1)" "$out"
check "the address is already off the link" "$(has_addr 192.168.1.2/24 && echo 1 || echo 0)" "$(cat "$ADDRS")"
check "and a reload is recorded as pending" "$([ -e "$STATE/reload-pending" ] && echo 0 || echo 1)"
: > "$CALLS"
out=$(run release); r=$?
check "the next run reloads even though the drop-in is gone" \
	"$([ $r -eq 0 ] && grep -qx 'reload' "$CALLS" && [ ! -e "$STATE/reload-pending" ] && echo 0 || echo 1)" "$out"
teardown

echo "14. no DHCP at all: the fallback stays (the case #53 exists for)"
setup end0 1 2 no
run >/dev/null
run lease-held >/dev/null; r=$?
check "no lease -> the release unit is skipped" "$([ $r -eq 1 ] && echo 0 || echo 1)"
check "the controlplane ends on 192.168.1.2/24, and only that" \
	"$([ "$(count)" = 1 ] && has_addr 192.168.1.2/24 && echo 0 || echo 1)" "$(cat "$ADDRS")"
teardown

echo "15. an unknown mode is refused"
setup end0 1 2 no
out=$(run bogus); r=$?
check "exits non-zero and writes nothing" "$([ $r -ne 0 ] && ! applied && echo 0 || echo 1)" "$out"
teardown

# --- 16. the release wiring -----------------------------------------------
# The script can only remove what systemd asks it to. These guard the unit
# properties the fix turns on; each comment says what breaks without it.
echo "16. the release is wired to the lease fact, level-triggered"
U="$ROOT/board/rasputin/common/rootfs-overlay/etc/systemd/system"
RP="$U/rasputin-fallback-address-release.path"; RS="$U/rasputin-fallback-address-release.service"
# PathChanged= would miss a lease that appears while the service runs.
check "path unit fires on a lease file (PathExistsGlob, not PathChanged)" \
	"$(grep -qx 'PathExistsGlob=/run/systemd/netif/leases/\*' "$RP" && ! grep -q '^PathChanged=' "$RP" && echo 0 || echo 1)"
check "path unit triggers the release service" \
	"$(grep -qx 'Unit=rasputin-fallback-address-release.service' "$RP" && echo 0 || echo 1)"
# Without RemainAfterExit=yes the level trigger re-runs the service forever.
check "release service stays active while the lease stands" "$(grep -qx 'RemainAfterExit=yes' "$RS" && echo 0 || echo 1)"
# A Condition*= that fails leaves the glob true and the service inactive: a trigger loop.
check "release service has no Condition*= (ExecCondition only)" \
	"$(grep -q '^Condition' "$RS" && echo 1 || echo 0)"
check "ExecCondition is the lease fact" \
	"$(grep -qx 'ExecCondition=/usr/lib/rasputin/netfallback/rasputin-fallback-address.sh lease-held' "$RS" && echo 0 || echo 1)"
check "ExecStart releases" \
	"$(grep -qx 'ExecStart=/usr/lib/rasputin/netfallback/rasputin-fallback-address.sh release' "$RS" && echo 0 || echo 1)"
check "release is ordered after the apply" \
	"$(grep -q '^After=.*rasputin-fallback-address\.service' "$RS" && echo 0 || echo 1)"
check "path unit enabled in post-build.sh" \
	"$(grep -q 'multi-user.target.wants/rasputin-fallback-address-release\.path' "$ROOT/board/rasputin/common/post-build.sh" && echo 0 || echo 1)"
# Standing rule: state changes follow checkable facts, never a timer.
check "no sleep or timeout in the script" \
	"$(grep -Eq '(^|[^a-z_])(sleep|timeout)[[:space:]]' "$SCRIPT" && echo 1 || echo 0)"

echo
if [ "$fails" -ne 0 ]; then echo "FAILED: $fails check(s)"; exit 1; fi
echo "all fallback-address tests passed"
