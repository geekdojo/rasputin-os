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
run_audit() {
	d="$1"; shift
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -g "$MYGID" -q "$@" 2>&1
	else
		"$SH" "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -g "$MYGID" -q "$@" 2>&1
	fi
}
audit_rc() {
	run_audit "$@" >/dev/null 2>&1
}
# run_audit_as UID ROOTDIR — the audit demanding a specific owner.
run_audit_as() {
	if [ "$SH" = busybox_sh ]; then
		busybox sh "$AUDIT" -i "$INVENTORY" -r "$2" -u "$1" -g "$MYGID" -q 2>&1
	else
		"$SH" "$AUDIT" -i "$INVENTORY" -r "$2" -u "$1" -g "$MYGID" -q 2>&1
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
		PATH="$s:$PATH" busybox sh "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -g "$MYGID" -q 2>&1
	else
		PATH="$s:$PATH" "$SH" "$AUDIT" -i "$INVENTORY" -r "$d" -u "$ME" -g "$MYGID" -q 2>&1
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
# root) and FI (the inventory). The shipped inventory declares no OWNER or
# GROUP column, so these one-line inventories are the only way to exercise
# them. Called directly, never in $(...), so FR and FI reach the caller.
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

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
	owner_group_cases
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
	sh "$AUDIT" -i "$INVENTORY" -r "$R" -u "$ME" -q 2>&1)
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
	sh "$AUDIT" -i "$INVENTORY" -r "$R" -u "$ME" -g "$MYGID" -q 2>&1)
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

echo "atrest-modes: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
