#!/bin/sh
#
# Tests for the at-rest mode audit (geekdojo/geekdojo-brain#494, gate 7).
#
# Why. The audit's verdict is the only thing the QEMU smoke can see — it has no
# shell into the guest — so a verdict that said PASS while a key sat at 0644
# would be worse than having no audit at all: the smoke would go green over it
# and everyone would stop looking. Nearly every case below is therefore a tree
# the audit MUST refuse, with the correct tree kept at the end so a failure
# there reads as "the audit broke", not "the fixture is wrong".
#
# How. The real script runs against synthetic trees under -r, so no root, no
# partitions and no systemd are needed. The inventory shipped in the image is
# the one used, so a path added to it is covered here from the next run.
#
# The static half checks the image's own declarations: no unit sets a UMask
# (a unit-level umask breaks the files that are 0644 on purpose, which is why
# the rule is per-file modes), and every directory the audit expects is
# actually created with a mode by something in this tree.
#
# Shells. Every case runs under each shell in TEST_SHELLS, as the other suites
# here do. REQUIRE_BUSYBOX=1 (CI sets it) fails the run when busybox is
# missing, since busybox ash is the image's /bin/sh.
#
# Run:  sh test/atrest-modes-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
AUDIT="$OVERLAY/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh"
INVENTORY="$OVERLAY/usr/lib/rasputin/atrest/inventory"
UNIT="$OVERLAY/etc/systemd/system/rasputin-atrest-audit.service"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
UNITDIR="$OVERLAY/etc/systemd/system"

for f in "$AUDIT" "$INVENTORY" "$UNIT"; do
	[ -f "$f" ] || { echo "missing: $f" >&2; exit 2; }
done

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAIL: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
SH=""

ok() {
	if [ "$2" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
not() { if "$@"; then return 1; else return 0; fi; }

# run_audit ROOTDIR [EXTRA...] — the audit over a synthetic tree, output
# captured. -q so the harness never writes to the host's kernel log, and -u
# with this user's id because a test cannot create root-owned files. The
# ownership check itself is exercised by the case that passes -u 0.
ME="$(id -u)"
run_audit() {
	d="$1"; shift
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -q "$@" 2>&1
	else
		"$SH" "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -q "$@" 2>&1
	fi
}
audit_rc() {
	run_audit "$@" >/dev/null 2>&1
}
# run_audit_as UID ROOTDIR — the audit demanding a specific owner.
run_audit_as() {
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$INVENTORY" -r "$2" -u "$1" -q 2>&1
	else
		"$SH" "$AUDIT" -i "$INVENTORY" -r "$2" -u "$1" -q 2>&1
	fi
}

# world — a tree that passes: every declared path present with its declared
# mode. Each case below then breaks exactly one thing, so a refusal is
# attributable to that one thing.
world() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	R="$W/root"
	V="$R/var/lib/rasputin"
	mkdir -p "$V"
	umask 077
	: >"$V/node.env"; chmod 0600 "$V/node.env"
	for d in bus agent-state trust mesh tailscale rauc dropbear coredump; do
		mkdir -p "$V/$d"; chmod 0700 "$V/$d"
	done
	: >"$V/bus/bus.key"; chmod 0600 "$V/bus/bus.key"
	: >"$V/bus/agent.token"; chmod 0600 "$V/bus/agent.token"
	: >"$V/bus/join.token"; chmod 0600 "$V/bus/join.token"
	umask 022
	echo "$R"
}

says() { printf '%s' "$2" | grep -qF -- "$1"; }

cases() {
	R=$(world)
	out=$(run_audit "$R")
	ok "a correct tree passes" "$(yes_if audit_rc "$R")" "$out"
	ok "a correct tree says PASS" "$(yes_if says 'rasputin-atrest: PASS' "$out")" "$out"
	ok "a correct tree reports how much it checked" \
		"$(yes_if says 'checked=' "$out")" "$out"

	# ── the paths the whole audit exists for ────────────────────────────────
	R=$(world); chmod 0644 "$R/var/lib/rasputin/node.env"
	out=$(run_audit "$R")
	ok "node.env at 0644 is refused" "$(yes_if not audit_rc "$R")" "$out"
	ok "node.env failure names the path and what it became" \
		"$(yes_if says 'node.env is 644, declared 0600' "$out")" "$out"

	R=$(world); chmod 0640 "$R/var/lib/rasputin/bus/bus.key"
	ok "a group-readable bus key is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0604 "$R/var/lib/rasputin/bus/agent.token"
	ok "a world-readable agent token is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0644 "$R/var/lib/rasputin/bus/join.token"
	ok "a world-readable join token is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0750 "$R/var/lib/rasputin/bus"
	ok "a group-executable bus directory is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0755 "$R/var/lib/rasputin/agent-state"
	ok "a world-readable agent-state directory is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0755 "$R/var/lib/rasputin/coredump"
	ok "a world-readable core store is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); chmod 0755 "$R/var/lib/rasputin/trust"
	ok "a world-readable trust directory is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	# ── the sweep: a file nobody declared ───────────────────────────────────
	R=$(world); : >"$R/var/lib/rasputin/bus/preseed.json"
	chmod 0644 "$R/var/lib/rasputin/bus/preseed.json"
	out=$(run_audit "$R")
	ok "an undeclared readable file in a swept tree is refused" \
		"$(yes_if not audit_rc "$R")" "$out"
	ok "the sweep names the file it found" \
		"$(yes_if says 'preseed.json is 644' "$out")" "$out"

	R=$(world); mkdir -p "$R/var/lib/rasputin/bus/sub"
	: >"$R/var/lib/rasputin/bus/sub/deep.key"; chmod 0644 "$R/var/lib/rasputin/bus/sub/deep.key"
	ok "the sweep reaches a nested file" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); : >"$R/var/lib/rasputin/bus/quiet"; chmod 0600 "$R/var/lib/rasputin/bus/quiet"
	ok "an owner-only file in a swept tree passes" "$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	# A tree that is NOT swept may hold a readable file: trust/ carries a
	# certificate a browser has to read, next to a key it must not.
	R=$(world); : >"$R/var/lib/rasputin/trust/mesh-ca.pem"
	chmod 0644 "$R/var/lib/rasputin/trust/mesh-ca.pem"
	ok "a readable certificate in an unswept tree passes" "$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	# ── presence ────────────────────────────────────────────────────────────
	R=$(world); rm -f "$R/var/lib/rasputin/node.env"
	out=$(run_audit "$R")
	ok "a missing required path is refused" "$(yes_if not audit_rc "$R")" "$out"
	ok "the missing path is named" "$(yes_if says 'node.env is missing' "$out")" "$out"

	R=$(world); rm -rf "$R/var/lib/rasputin/coredump" "$R/var/lib/rasputin/rauc"
	ok "missing optional paths pass — they belong to one role" \
		"$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	# ── ownership ───────────────────────────────────────────────────────────
	# On the appliance every declared path belongs to root. A tree this test
	# owns is refused when the audit is asked for root, which is the check the
	# real run makes on every path.
	R=$(world)
	out=$(run_audit_as 0 "$R")
	ok "a path owned by the wrong uid is refused" \
		"$(yes_if says 'is owned by uid' "$out")" "$out"

	# ── the audit's own inputs ──────────────────────────────────────────────
	R=$(world)
	out=$(
		if [ "$SH" = busybox_sh ]; then
			busybox sh "$AUDIT" -i "$TMP/no-such-inventory" -r "$R" -u "$ME" -q 2>&1
		else
			"$SH" "$AUDIT" -i "$TMP/no-such-inventory" -r "$R" -u "$ME" -q 2>&1
		fi
	)
	ok "an unreadable inventory is a FAIL, never a quiet pass" \
		"$(yes_if says 'FAIL inventory unreadable' "$out")" "$out"

	# An empty tree must not read as success. Nothing to check is not the same
	# answer as everything checked out, and node.env is required for exactly
	# this reason.
	empty=$(mktemp -d "$TMP/e.XXXXXX")
	ok "an empty tree is refused" "$(yes_if not audit_rc "$empty")" "$(run_audit "$empty")"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
done

# ── the image's own declarations, shell-independent ─────────────────────────
SH=unit

# No unit-level UMask. It was proposed and rejected: it breaks the files that
# are 0644 on purpose (the resolved drop-in, the observability configs), which
# is why the rule is a mode per file instead.
ok "no unit sets a UMask" \
	"$(yes_if not grep -rqE '^[[:space:]]*UMask=' "$UNITDIR")" \
	"$(grep -rn '^[[:space:]]*UMask=' "$UNITDIR" 2>/dev/null)"

# Every directory the audit expects at 0700 has to be created with that mode by
# something in this tree, or the audit is asserting a mode nothing sets.
for d in tailscale mesh rauc dropbear trust agent-state; do
	ok "tmpfiles.d declares /var/lib/rasputin/$d 0700" \
		"$(yes_if grep -qE "^d /var/lib/rasputin/$d[[:space:]]+0700" "$TMPFILES")" \
		"$(grep -n "$d" "$TMPFILES")"
done

# The core store is created by its own unit, not tmpfiles.d (a baked symlink
# cannot work there — see that unit). So the mode has to be set in the unit.
ok "the coredump store unit sets an explicit mode" \
	"$(yes_if grep -qE '^ExecStart=/bin/chmod 0700 /var/lib/rasputin/coredump' \
		"$UNITDIR/rasputin-coredump-store.service")" \
	"$(grep -n ExecStart "$UNITDIR/rasputin-coredump-store.service")"

# The audit runs on every boot and must never take a boot down with it.
ok "the audit unit is a oneshot" \
	"$(yes_if grep -qx 'Type=oneshot' "$UNIT")" "$(cat "$UNIT")"
ok "the audit unit cannot fail the boot" \
	"$(yes_if grep -qx 'SuccessExitStatus=0 1' "$UNIT")" "$(cat "$UNIT")"
ok "the audit unit is enabled at multi-user" \
	"$(yes_if grep -qx 'WantedBy=multi-user.target' "$UNIT")" "$(cat "$UNIT")"
ok "the audit unit runs after the api has written its files" \
	"$(yes_if grep -qE '^After=.*rasputin-api\.service' "$UNIT")" "$(cat "$UNIT")"

# The inventory is the audit's whole input, so an empty one would make every
# run report PASS over nothing.
ok "the inventory declares at least one required path" \
	"$(yes_if grep -qE '^[0-7]{4}[[:space:]]+required[[:space:]]+/' "$INVENTORY")" \
	"$(cat "$INVENTORY")"
ok "the inventory declares at least one swept tree" \
	"$(yes_if grep -qE '^sweep[[:space:]]+/' "$INVENTORY")" "$(cat "$INVENTORY")"

echo "atrest-modes: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
