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
# captured. -q so the harness never writes to the host's kernel log, and -u and
# -g with this user's ids because a test cannot create root-owned files. They
# set only the DEFAULT for an entry with no OWNER or GROUP column; the
# ownership checks themselves are exercised by the cases that pass -u 0, or
# leave -g out, and by the fixture rows that declare the columns.
ME="$(id -u)"
MYGID="$(id -g)"

# The harness inventory. The shipped one declares the store's directories as
# uid and gid 990 (geekdojo/geekdojo-brain#754), and a test cannot create files
# owned by 990, so the run_audit helpers read a copy in which every DECLARED
# OWNER and GROUP column is rewritten to this user's ids. Only columns 4 and 5
# of mode rows change: ownership is still compared, against an id the harness
# can own. TC-754-13 below proves the copy differs in nothing else, and
# TC-754-08 runs the shipped file unrewritten to prove 990 is enforced.
SHIPPED_SUM_BEFORE="$(cksum <"$INVENTORY")"
HARNESS_INV="$TMP/inventory.harness"
awk -v u="$ME" -v g="$MYGID" '
	$1 ~ /^[0-7][0-7][0-7][0-7]$/ && NF >= 4 { $4 = u; if (NF >= 5) $5 = g }
	{ print }
' "$INVENTORY" >"$HARNESS_INV" || { echo "could not write the harness inventory" >&2; exit 2; }

# The store's paths (geekdojo/geekdojo-brain#754), written here as literals and
# never read from the inventory, so a row dropped from it or declared with the
# wrong owner fails a case below instead of quietly shrinking the table.
VAR_RASPUTIN=/var/lib/rasputin
STORE_DIRS="$VAR_RASPUTIN/openbao $VAR_RASPUTIN/openbao-audit $VAR_RASPUTIN/openbao-seal $VAR_RASPUTIN/tls $VAR_RASPUTIN/tls/openbao-server $VAR_RASPUTIN/tls/openbao-client"
STORE_FILES="$VAR_RASPUTIN/openbao-seal/seal-key $VAR_RASPUTIN/openbao-seal/seal.hcl $VAR_RASPUTIN/tls/openbao-server/leaf.key $VAR_RASPUTIN/tls/openbao-client/leaf.key"
# The store's own uid owns these two; root owns every other store path.
STORE_OWNED="$VAR_RASPUTIN/openbao $VAR_RASPUTIN/openbao-audit"
STORE_ROOT_OWNED="$VAR_RASPUTIN/openbao-seal $VAR_RASPUTIN/openbao-seal/seal-key $VAR_RASPUTIN/openbao-seal/seal.hcl $VAR_RASPUTIN/tls $VAR_RASPUTIN/tls/openbao-server $VAR_RASPUTIN/tls/openbao-server/leaf.key $VAR_RASPUTIN/tls/openbao-client $VAR_RASPUTIN/tls/openbao-client/leaf.key"
OPENBAO_ID=990

run_audit() {
	d="$1"; shift
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$HARNESS_INV" -r "$d" -u "$ME" -g "$MYGID" -q "$@" 2>&1
	else
		"$SH" "$AUDIT" -i "$HARNESS_INV" -r "$d" -u "$ME" -g "$MYGID" -q "$@" 2>&1
	fi
}
audit_rc() {
	run_audit "$@" >/dev/null 2>&1
}
# run_audit_as UID ROOTDIR — the audit demanding a specific owner.
run_audit_as() {
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$HARNESS_INV" -r "$2" -u "$1" -g "$MYGID" -q 2>&1
	else
		"$SH" "$AUDIT" -i "$HARNESS_INV" -r "$2" -u "$1" -g "$MYGID" -q 2>&1
	fi
}

# stub_without TOOL... — a directory holding a stub for each named tool that
# exits 127, which is what calling a binary the image does not ship looks like
# to this script. Prepended to PATH rather than replacing it, so the audit's
# other tools (mktemp, wc, head) still resolve: what is staged is the absence
# of one binary, not a bare environment.
stub_without() {
	_s=$(mktemp -d "$TMP/stub.XXXXXX")
	for _t in "$@"; do
		printf '#!/bin/sh\nexit 127\n' >"$_s/$_t"
		chmod 0755 "$_s/$_t"
	done
	echo "$_s"
}

# run_audit_without ROOTDIR TOOL... — the audit with those tools unavailable.
run_audit_without() {
	d="$1"; shift
	s=$(stub_without "$@")
	if [ "$SH" = busybox_sh ]; then
		PATH="$s:$PATH" busybox sh "$AUDIT" -i "$HARNESS_INV" -r "$d" -u "$ME" -g "$MYGID" -q 2>&1
	else
		PATH="$s:$PATH" "$SH" "$AUDIT" -i "$HARNESS_INV" -r "$d" -u "$ME" -g "$MYGID" -q 2>&1
	fi
}
audit_rc_without() {
	run_audit_without "$@" >/dev/null 2>&1
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
	for d in bus agent-state trust mesh tailscale rauc dropbear coredump console journal; do
		mkdir -p "$V/$d"; chmod 0700 "$V/$d"
	done
	# /etc/shadow lives here: a baked-in symlink points at it so the control
	# plane can deliver a root password hash to a read-only rootfs
	# (geekdojo/geekdojo-brain#546). Required, so a correct tree has it.
	: >"$V/console/shadow"; chmod 0600 "$V/console/shadow"
	: >"$V/bus/bus.key"; chmod 0600 "$V/bus/bus.key"
	: >"$V/bus/agent.token"; chmod 0600 "$V/bus/agent.token"
	: >"$V/bus/join.token"; chmod 0600 "$V/bus/join.token"
	# The secrets store's six directories and its four secret files
	# (geekdojo/geekdojo-brain#754), each at its declared mode.
	for d in $STORE_DIRS; do
		mkdir -p "$R$d"; chmod 0700 "$R$d"
	done
	for f in $STORE_FILES; do
		: >"$R$f"; chmod 0600 "$R$f"
	done
	umask 022
	# On BSD and macOS a new file takes its DIRECTORY's group, not the
	# creator's, so the group the audit reads would depend on where mktemp
	# put the tree. Set it, so the expected gid is this user's on every host.
	chgrp -R "$MYGID" "$R"
	echo "$R"
}

says() { printf '%s' "$2" | grep -qF -- "$1"; }
# last_line_matches ERE OUTPUT — the verdict is the audit's last line, and the
# smoke parses it, so its shape is asserted on that line alone.
last_line_matches() { printf '%s\n' "$2" | tail -n 1 | grep -qE -- "$1"; }

# fixture MODE ENTRY — a tree holding one file, /x, at MODE and owned by this
# user and group, and an inventory holding the one line ENTRY. Sets FR (the
# root) and FI (the inventory). These one-line inventories exercise the OWNER
# and GROUP columns on their own; the store's rows in the shipped inventory
# exercise them in place (store_cases). Called directly, never in $(...), so
# FR and FI reach the caller.
fixture() {
	_fw=$(mktemp -d "$TMP/f.XXXXXX")
	FR="$_fw/root"
	FI="$_fw/inventory"
	mkdir -p "$FR"
	: >"$FR/x"
	chmod "$1" "$FR/x"
	chgrp "$MYGID" "$FR/x"
	printf '%s\n' "$2" >"$FI"
}

# audit_with INVENTORY ROOTDIR FLAGS... — the audit with exactly the flags
# given and no harness defaults, so a case can run it as production does.
audit_with() {
	_i="$1"; _r="$2"; shift 2
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$_i" -r "$_r" -q "$@" 2>&1
	else
		"$SH" "$AUDIT" -i "$_i" -r "$_r" -q "$@" 2>&1
	fi
}

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
		"$(yes_if says 'node.env is 0644, declared 0600' "$out")" "$out"

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
	R=$(world); : >"$R/var/lib/rasputin/agent-state/undeclared.json"
	chmod 0644 "$R/var/lib/rasputin/agent-state/undeclared.json"
	out=$(run_audit "$R")
	ok "an undeclared readable file in a swept tree is refused" \
		"$(yes_if not audit_rc "$R")" "$out"
	ok "the sweep names the file it found" \
		"$(yes_if says 'undeclared.json is 0644' "$out")" "$out"

	R=$(world); mkdir -p "$R/var/lib/rasputin/agent-state/sub"
	: >"$R/var/lib/rasputin/agent-state/sub/deep.key"
	chmod 0644 "$R/var/lib/rasputin/agent-state/sub/deep.key"
	ok "the sweep reaches a nested file" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); : >"$R/var/lib/rasputin/agent-state/quiet"
	chmod 0600 "$R/var/lib/rasputin/agent-state/quiet"
	ok "an owner-only file in a swept tree passes" "$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	# A tree that is NOT swept may hold a readable file: trust/ carries a
	# certificate a browser has to read, next to a key it must not.
	R=$(world); : >"$R/var/lib/rasputin/trust/mesh-ca.pem"
	chmod 0644 "$R/var/lib/rasputin/trust/mesh-ca.pem"
	ok "a readable certificate in an unswept tree passes" "$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	# bus/ carries the same shape and now the same exemption: bus.crt is an
	# X.509 certificate and agent.pin a public-key pin, both public by
	# construction, sitting next to the key and the token that are not. The
	# 0700 directory is what keeps those unreachable, and each of them is
	# declared by name above, so the exemption uncovers nothing.
	R=$(world)
	: >"$R/var/lib/rasputin/bus/bus.crt"; chmod 0644 "$R/var/lib/rasputin/bus/bus.crt"
	: >"$R/var/lib/rasputin/bus/agent.pin"; chmod 0644 "$R/var/lib/rasputin/bus/agent.pin"
	ok "the bus certificate and agent pin pass — public by construction" \
		"$(yes_if audit_rc "$R")" "$(run_audit "$R")"

	R=$(world); : >"$R/var/lib/rasputin/bus/issuer.nk"
	chmod 0644 "$R/var/lib/rasputin/bus/issuer.nk"
	ok "the bus issuer key is still refused at 0644 — the exemption is per file" \
		"$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

	# ── the mode reader must not need stat(1) ───────────────────────────────
	# The image ships no stat at all: busybox is built without the applet and
	# there is no coreutils. The reader that shipped probed for GNU stat and
	# fell back to the BSD spelling, so on the image both branches called a
	# missing binary, every mode came back empty, and every node logged
	# "is , declared 0600" on every boot (geekdojo/geekdojo-brain#494). This
	# runner HAS stat, which is exactly why the bug was unreachable here, so
	# the absence is staged with a stub that exits 127.
	R=$(world)
	out=$(run_audit_without "$R" stat)
	ok "a correct tree passes with no stat(1) available" \
		"$(yes_if audit_rc_without "$R" stat)" "$out"
	ok "with no stat(1) the verdict is still PASS" \
		"$(yes_if says 'rasputin-atrest: PASS' "$out")" "$out"

	R=$(world); chmod 0644 "$R/var/lib/rasputin/node.env"
	out=$(run_audit_without "$R" stat)
	ok "with no stat(1) a widened declared mode is still refused" \
		"$(yes_if not audit_rc_without "$R" stat)" "$out"
	ok "with no stat(1) the mode is still read, not left empty" \
		"$(yes_if says 'node.env is 0644, declared 0600' "$out")" "$out"

	R=$(world); : >"$R/var/lib/rasputin/agent-state/nostat.json"
	chmod 0644 "$R/var/lib/rasputin/agent-state/nostat.json"
	out=$(run_audit_without "$R" stat)
	ok "with no stat(1) the sweep still catches an undeclared readable file" \
		"$(yes_if says 'nostat.json is 0644' "$out")" "$out"

	# A setuid bit must not read as an ordinary mode, or a setuid root binary
	# dropped into a declared path would compare equal to its declaration.
	R=$(world); chmod 4600 "$R/var/lib/rasputin/node.env"
	ok "a setuid declared path is refused" "$(yes_if not audit_rc "$R")" "$(run_audit "$R")"

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

# ── declared OWNER and GROUP columns (geekdojo/geekdojo-brain#734) ──────────
# An entry may name the uid and gid it belongs to, for a path a non-root
# service owns. Every case above is the other half (TC-734-11): entries with
# no columns, which must keep exactly the root, owner-only contract they had.
owner_group_cases() {
	# TC-734-01: declared columns accept declared group access, under the
	# shipped defaults -u 0 -g 0. This is the shape a store owned by its own
	# user takes: root defaults, explicit non-root columns that still PASS.
	fixture 0640 "0640 required /x $ME $MYGID"
	out=$(audit_with "$FI" "$FR" -u 0 -g 0); rc=$?
	ok "TC-734-01 declared owner and group with group access pass under the 0:0 defaults" \
		"$(yes_if [ "$rc" -eq 0 ])" "$out"
	ok "TC-734-01 the verdict is PASS" "$(yes_if says 'rasputin-atrest: PASS' "$out")" "$out"
	# TC-734-12: a PASS verdict keeps the shape the smoke parses.
	ok "TC-734-12 a PASS verdict is exactly 'PASS checked=N'" \
		"$(yes_if last_line_matches '^rasputin-atrest: PASS checked=1$' "$out")" "$out"

	# TC-734-02: a declared OWNER is compared as written; -u never overrides it.
	fixture 0600 "0600 required /x $((ME + 1)) $MYGID"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-02 a wrong declared owner is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-02 the failure names the uid found and the one declared" \
		"$(yes_if says "is owned by uid $ME, not $((ME + 1))" "$out")" "$out"

	# TC-734-03: a declared GROUP is compared as written; -g never overrides it.
	fixture 0600 "0600 required /x $ME $((MYGID + 1))"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-03 a wrong declared group is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-03 the failure names the gid found and the one declared" \
		"$(yes_if says "is group gid $MYGID, not $((MYGID + 1))" "$out")" "$out"
	# TC-734-12: a FAIL verdict keeps the shape the smoke parses.
	ok "TC-734-12 a FAIL verdict keeps its shape and carries the group finding" \
		"$(yes_if last_line_matches '^rasputin-atrest: FAIL failures=1 checked=1 first=FAIL .*group gid' "$out")" "$out"

	# TC-734-04: declared columns do not loosen the exact mode.
	fixture 0640 "0600 required /x $ME $MYGID"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-04 a wrong mode is refused even with owner and group declared" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-04 the failure names the mode found and the one declared" \
		"$(yes_if says 'is 0640, declared 0600' "$out")" "$out"

	# TC-734-05: world access is refused even when mode, owner and group all
	# match the declaration, and with or without columns.
	fixture 0644 "0644 required /x $ME $MYGID"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-05 world access is refused with every column matching" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-05 the failure says it grants world access" \
		"$(yes_if says 'grants world access' "$out")" "$out"
	fixture 0604 "0604 required /x"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-05 world access is refused on an entry with no columns" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-05 that failure also says it grants world access" \
		"$(yes_if says 'grants world access' "$out")" "$out"

	# TC-734-06: group access needs a declared GROUP. An OWNER alone is not one.
	fixture 0640 "0640 required /x"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-06 group access with no columns is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-06 the failure says no group is declared" \
		"$(yes_if says 'grants group access and declares no group' "$out")" "$out"
	fixture 0640 "0640 required /x $ME"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-06 group access with an OWNER only is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-06 that failure also says no group is declared" \
		"$(yes_if says 'grants group access and declares no group' "$out")" "$out"

	# TC-734-07: an entry with an OWNER only takes the group default.
	fixture 0600 "0600 required /x $ME"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-07 an owner-only entry passes when the group default matches" \
		"$(yes_if [ "$rc" -eq 0 ])" "$out"
	ok "TC-734-07 that verdict is PASS" "$(yes_if says 'rasputin-atrest: PASS' "$out")" "$out"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g 0)
	ok "TC-734-07 an owner-only entry is held to the group default when it differs" \
		"$(yes_if says "is group gid $MYGID, not 0" "$out")" "$out"

	# TC-734-08: with no -g, the default gid is root's, as it is in production
	# (the unit passes no flags). Over the shipped inventory and a correct
	# tree this user owns, every entry is held to gid 0.
	R=$(world)
	out=$(audit_with "$INVENTORY" "$R" -u "$ME"); rc=$?
	ok "TC-734-08 with no -g a correct tree owned by a non-root group is refused" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-08 the failure says the default gid is 0" \
		"$(yes_if says "is group gid $MYGID, not 0" "$out")" "$out"

	# TC-734-09: names are never resolved, so a name fails and names itself.
	fixture 0600 "0600 required /x openbao"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-09 an OWNER given as a name is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-09 the failure names the owner name" "$(yes_if says 'not openbao' "$out")" "$out"
	fixture 0600 "0600 required /x $ME openbao"
	out=$(audit_with "$FI" "$FR" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-734-09 a GROUP given as a name is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-734-09 the failure names the group name" "$(yes_if says 'not openbao' "$out")" "$out"
}

# ── the secrets store's paths (geekdojo/geekdojo-brain#754) ─────────────────
# Six directories and four secret files. Every case here runs over the shipped
# inventory's own rows: the harness copy for the cases a test user can stage,
# the shipped file unrewritten for the one that proves 990 is enforced.
# passed RC OUTPUT — the audit exited 0 AND said PASS.
passed() { [ "$1" -eq 0 ] && says 'rasputin-atrest: PASS' "$2"; }

store_cases() {
	R=$(world)
	V="$R/var/lib/rasputin"

	# TC-754-05: a correct tree passes with the new rows. Before #754 a
	# correct tree checked 16: fifteen declared paths, plus console/shadow
	# visited again by its sweep. #754 adds ten declared paths and the
	# sweep of openbao-seal/, which visits seal-key and seal.hcl again, so 28.
	out=$(run_audit "$R"); rc=$?
	ok "TC-754-05 a correct tree with the store's paths passes" "$(yes_if [ "$rc" -eq 0 ])" "$out"
	ok "TC-754-05 the verdict is exactly 'PASS checked=28'" \
		"$(yes_if last_line_matches '^rasputin-atrest: PASS checked=28$' "$out")" "$out"

	# TC-754-06 and TC-754-07: undeclared group access and world access, one
	# new row at a time, each restored before the next.
	for p in $STORE_DIRS $STORE_FILES; do
		if [ -d "$R$p" ]; then want=0700; g=0740; w=0704
		else want=0600; g=0640; w=0604; fi

		chmod g+r "$R$p"
		out=$(run_audit "$R"); rc=$?
		chmod g-r "$R$p"
		ok "TC-754-06 group access on $p is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
		ok "TC-754-06 the failure names $p and its mode" \
			"$(yes_if says "$p is $g, declared $want" "$out")" "$out"

		chmod o+r "$R$p"
		out=$(run_audit "$R"); rc=$?
		chmod o-r "$R$p"
		ok "TC-754-07 world access on $p is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
		ok "TC-754-07 the failure names $p and its mode" \
			"$(yes_if says "$p is $w, declared $want" "$out")" "$out"
	done

	# TC-754-08: wrong owner on the store-owned rows. The shipped inventory,
	# unrewritten, over a tree this user owns: 990 is compared as written.
	ok "TC-754-08 precondition: the harness uid is not $OPENBAO_ID" \
		"$(yes_if [ "$ME" != "$OPENBAO_ID" ])" "uid=$ME"
	out=$(audit_with "$INVENTORY" "$R" -u "$ME" -g "$MYGID"); rc=$?
	ok "TC-754-08 the shipped inventory refuses store paths not owned by $OPENBAO_ID" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	for p in $STORE_OWNED; do
		ok "TC-754-08 $p is held to uid $OPENBAO_ID" \
			"$(yes_if says "$p is owned by uid $ME, not $OPENBAO_ID" "$out")" "$out"
	done

	# TC-754-09: wrong owner on the root rows. With root demanded as the
	# default, every root-owned store path is refused; the two store-owned
	# directories, which declare their owner, are not.
	out=$(run_audit_as 0 "$R")
	for p in $STORE_ROOT_OWNED; do
		ok "TC-754-09 $p is held to uid 0" \
			"$(yes_if says "$p is owned by uid $ME, not 0" "$out")" "$out"
	done
	for p in $STORE_OWNED; do
		ok "TC-754-09 $p is not held to uid 0 — it declares its owner" \
			"$(yes_if not says "$p is owned by uid $ME, not 0" "$out")" "$out"
	done

	# TC-754-10: the new sweep row catches a file nobody declared.
	: >"$V/openbao-seal/stray"; chmod 0644 "$V/openbao-seal/stray"
	out=$(run_audit "$R"); rc=$?
	rm -f "$V/openbao-seal/stray"
	ok "TC-754-10 an undeclared readable file in openbao-seal is refused" \
		"$(yes_if [ "$rc" -ne 0 ])" "$out"
	ok "TC-754-10 the sweep names it" \
		"$(yes_if says 'openbao-seal/stray is 0644 in a swept tree' "$out")" "$out"

	# TC-754-11: the leaf directories and the store's own directories are not
	# swept. A leaf certificate is public by construction (the api writes it
	# 0644), and the store sets the modes of its own files.
	R2=$(world); V2="$R2/var/lib/rasputin"
	for d in openbao-server openbao-client; do
		: >"$V2/tls/$d/leaf.pem"; chmod 0644 "$V2/tls/$d/leaf.pem"
	done
	out=$(run_audit "$R2"); rc=$?
	ok "TC-754-11 a public leaf certificate in an unswept store directory passes" \
		"$(yes_if passed "$rc" "$out")" "$out"
	R2=$(world); V2="$R2/var/lib/rasputin"
	: >"$V2/openbao/data.db"; chmod 0644 "$V2/openbao/data.db"
	: >"$V2/openbao-audit/audit.log"; chmod 0644 "$V2/openbao-audit/audit.log"
	out=$(run_audit "$R2"); rc=$?
	ok "TC-754-11 store-owned contents are not swept" \
		"$(yes_if passed "$rc" "$out")" "$out"

	# TC-754-12: the directories are required, the files optional.
	for p in $STORE_DIRS; do
		R2=$(world); rm -rf "$R2$p"
		out=$(run_audit "$R2"); rc=$?
		ok "TC-754-12 a missing $p is refused" "$(yes_if [ "$rc" -ne 0 ])" "$out"
		ok "TC-754-12 the failure says $p is required" \
			"$(yes_if says "$p is missing and is required" "$out")" "$out"
	done
	R2=$(world)
	for f in $STORE_FILES; do rm -f "$R2$f"; done
	out=$(run_audit "$R2"); rc=$?
	ok "TC-754-12 with none of the four secret files written yet the tree passes" \
		"$(yes_if passed "$rc" "$out")" "$out"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
	owner_group_cases
	store_cases
done

# ── an unreadable mode is a FAIL, never an empty one ───────────────────────
# With no reader at all the audit must say so, and say which path. What shipped
# instead compared "" against a declared mode — "is , declared 0600", a message
# that points at the modes rather than at the reader — and skipped every swept
# file outright.
#
# One run, not one per shell: what this pins is what the script does with a
# reader that answered nothing, which is shell-independent. It is deliberately
# not run under busybox ash, because taking a tool away from busybox's own
# shell is not something PATH can be relied on to do — busybox may resolve its
# applets internally — and a case whose setup might silently not take effect is
# worse than no case at all.
SH=reader
R=$(world)
out=$(PATH="$(stub_without stat find):$PATH" \
	sh "$AUDIT" -i "$HARNESS_INV" -r "$R" -u "$ME" -q 2>&1)
ok "a mode that cannot be read is a FAIL" \
	"$(yes_if says 'rasputin-atrest: FAIL' "$out")" "$out"
ok "the failure says the mode could not be read and names the path" \
	"$(yes_if says 'node.env mode could not be read' "$out")" "$out"
ok "an unreadable mode is never rendered as an empty mode" \
	"$(yes_if not says 'is , declared' "$out")" "$out"

# ── an unreadable owner or group is a FAIL, never a skip ───────────────────
# TC-734-10. The same rule, and the same reason for running under sh only, as
# the unreadable-mode case above: with no `ls` the owner and group reader
# answers nothing, and that must fail the path, not pass it.
SH=owner-reader
R=$(world)
out=$(PATH="$(stub_without ls):$PATH" \
	sh "$AUDIT" -i "$HARNESS_INV" -r "$R" -u "$ME" -g "$MYGID" -q 2>&1)
ok "TC-734-10 the failure says the owner or group could not be read and names the path" \
	"$(yes_if says 'node.env owner or group could not be read' "$out")" "$out"
ok "TC-734-10 an unreadable owner or group is a FAIL" \
	"$(yes_if says 'rasputin-atrest: FAIL' "$out")" "$out"
ok "TC-734-10 an unreadable owner or group is never a PASS" \
	"$(yes_if not says 'rasputin-atrest: PASS' "$out")" "$out"

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

# The journal store is the same shape: its own unit creates it, because it has
# to exist before systemd-journal-flush.service and tmpfiles-setup runs after
# that. So the mode has to be set in the unit — and then HELD there by a
# tmpfiles file that sorts after stock systemd.conf, which resets
# /var/log/journal (the same inode) to 2755 root:systemd-journal on every boot.
# test/persistent-journal-test.sh covers the rest of that arrangement.
ok "the journal store unit sets an explicit mode" \
	"$(yes_if grep -qE '^ExecStart=/bin/chmod 0700 /var/lib/rasputin/journal' \
		"$UNITDIR/rasputin-journal-store.service" 2>/dev/null)" \
	"$(grep -n ExecStart "$UNITDIR/rasputin-journal-store.service" 2>&1)"

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

# ── the secrets store's declarations (geekdojo/geekdojo-brain#754) ─────────
# tmpfiles_d PATH — "MODE UID GID" of PATH's `d` line, with root read as 0 the
# way the audit reads it. One line per `d` line naming PATH, so a duplicate
# shows up as two and never equals a single expected line.
tmpfiles_d() {
	awk -v p="$1" '$1 == "d" && $2 == p {
		u = ($4 == "root") ? 0 : $4; g = ($5 == "root") ? 0 : $5
		print $3, u, g
	}' "$TMPFILES"
}
# inv_row PATH — "MODE PRESENCE UID GID NF" of PATH's inventory row, with an
# absent OWNER or GROUP read as the audit's production default, 0.
inv_row() {
	awk -v p="$1" '$1 ~ /^[0-7][0-7][0-7][0-7]$/ && $3 == p {
		u = (NF >= 4) ? $4 : 0; g = (NF >= 5) ? $5 : 0
		print $1, $2, u, g, NF
	}' "$INVENTORY"
}
# d_line_is PATH MODE UID GID — PATH has exactly one `d` line, and it carries
# MODE, UID and GID.
d_line_is() { [ "$(tmpfiles_d "$1")" = "$2 $3 $4" ]; }

# TC-754-01: the six `d` lines, exactly once each, with the values written here
# rather than read from the inventory.
while read -r rel mode uid gid; do
	p="$VAR_RASPUTIN/$rel"
	ok "TC-754-01 tmpfiles.d declares $p once, $mode $uid:$gid" \
		"$(yes_if d_line_is "$p" "$mode" "$uid" "$gid")" \
		"d lines for $p: $(tmpfiles_d "$p")"
done <<'EOF_D'
openbao 0700 990 990
openbao-audit 0700 990 990
openbao-seal 0700 0 0
tls 0700 0 0
tls/openbao-server 0700 0 0
tls/openbao-client 0700 0 0
EOF_D

# TC-754-02: each directory's inventory row matches its `d` line and is
# required; each secret file is an optional 0600 row with no OWNER or GROUP;
# openbao-seal is swept and no other store directory is.
# row_matches_d PATH — the inventory row has the `d` line's mode, uid and gid.
row_matches_d() {
	_want=$(tmpfiles_d "$1" | awk '{ print $1, "required", $2, $3 }')
	[ -n "$_want" ] && [ "$(inv_row "$1" | awk '{ print $1, $2, $3, $4 }')" = "$_want" ]
}
for p in $STORE_DIRS; do
	ok "TC-754-02 the inventory declares $p required, as its d line does" \
		"$(yes_if row_matches_d "$p")" \
		"d: $(tmpfiles_d "$p") | inventory: $(inv_row "$p")"
done
for p in $STORE_FILES; do
	ok "TC-754-02 the inventory declares $p optional 0600 with no OWNER or GROUP" \
		"$(yes_if [ "$(inv_row "$p")" = "0600 optional 0 0 3" ])" \
		"inventory: $(inv_row "$p")"
done
sweeps=$(awk '$1 == "sweep" { print $2 }' "$INVENTORY")
# listed LINE TEXT — LINE is one whole line of TEXT.
listed() { printf '%s\n' "$2" | grep -qxF -- "$1"; }
ok "TC-754-02 openbao-seal is swept" \
	"$(yes_if listed "$VAR_RASPUTIN/openbao-seal" "$sweeps")" "$sweeps"
for p in "$VAR_RASPUTIN/openbao" "$VAR_RASPUTIN/openbao-audit" "$VAR_RASPUTIN/tls" \
	"$VAR_RASPUTIN/tls/openbao-server" "$VAR_RASPUTIN/tls/openbao-client"; do
	ok "TC-754-02 $p is not swept" \
		"$(yes_if not listed "$p" "$sweeps")" "$sweeps"
done

# TC-754-03: no tmpfiles line creates or repairs a store FILE. Every line naming
# a store path is a `d`, and no line of a file-creating or repairing type names
# a store file.
bad=$(awk '
	/^[[:space:]]*(#|$)/ { next }
	$2 ~ /^\/var\/lib\/rasputin\/(openbao|tls\/openbao-)/ && $1 != "d" { print; next }
	substr($1, 1, 1) ~ /[fFwzZCL]/ && $2 ~ /(seal-key|seal\.hcl|leaf\.key|leaf\.pem)$/ { print }
' "$TMPFILES")
ok "TC-754-03 no tmpfiles line other than d names a store path" \
	"$(yes_if [ -z "$bad" ])" "offending: $bad"

# TC-754-13: the harness inventory differs from the shipped one only in the
# declared OWNER and GROUP columns, which it sets to this user's ids.
diffs=$(awk -v u="$ME" -v g="$MYGID" '
	NR == FNR { shipped[FNR] = $0; n = FNR; next }
	{
		m = FNR
		nf = split(shipped[FNR], f)
		if (f[1] ~ /^[0-7][0-7][0-7][0-7]$/ && nf >= 4) {
			if (NF != nf || $1 != f[1] || $2 != f[2] || $3 != f[3] || $4 != u || (nf >= 5 && $5 != g))
				print "line " FNR ": " shipped[FNR] " -> " $0
		} else if ($0 != shipped[FNR]) {
			print "line " FNR ": " shipped[FNR] " -> " $0
		}
	}
	END { if (m != n) print "line counts differ: " n " shipped, " m " harness" }
' "$INVENTORY" "$HARNESS_INV")
ok "TC-754-13 the harness inventory differs from the shipped one only in declared owner and group" \
	"$(yes_if [ -z "$diffs" ])" "$diffs"
ok "TC-754-13 the harness inventory keeps every non-comment line" \
	"$(yes_if [ "$(grep -Ecv '^[[:space:]]*(#|$)' "$INVENTORY")" = "$(grep -Ecv '^[[:space:]]*(#|$)' "$HARNESS_INV")" ])"
ok "TC-754-13 the harness inventory keeps every sweep line" \
	"$(yes_if [ "$(grep '^sweep' "$INVENTORY")" = "$(grep '^sweep' "$HARNESS_INV")" ])"
ok "TC-754-13 the harness inventory rewrote both store-owned rows" \
	"$(yes_if [ "$(awk -v u="$ME" -v g="$MYGID" '$4 == u && $5 == g' "$HARNESS_INV" | grep -c 'rasputin/openbao')" -eq 2 ])" \
	"$(grep openbao "$HARNESS_INV")"
ok "TC-754-13 the shipped inventory is untouched" \
	"$(yes_if [ "$(cksum <"$INVENTORY")" = "$SHIPPED_SUM_BEFORE" ])"

echo "atrest-modes: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
