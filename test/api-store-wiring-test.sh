#!/bin/sh
# Static assertions on how rasputin-api.service is wired to the secrets store,
# plus the api pin guard (geekdojo/geekdojo-brain#757).
#
# Why. The api unit selects the store with two Environment= lines and pulls it
# in with one Wants=. Every way to get one wrong is silent: a selector in the
# wrong case leaves the store off with one log line, a second assignment
# trailing on another line wins over the first, and a Requires= in place of
# Wants= restarts the api with every store restart. So the lines are pinned
# byte-exact, the hard dependencies are refused, and negative controls show the
# checker refuses each wrong copy, naming its line.
#
# The pin guard (F-757-01). The selector is what arms an api release with the
# store client to mint the store's server leaf and restart the store. Until the
# store's main config ships in the overlay, that store cannot run, so a pin
# bump would crash-loop it on every control plane. While the config named by
# openbao.service's first -config= is absent from the overlay, the guard holds
# RASPUTIN_API_VERSION at the last api release without the store client. Once
# the config exists, the guard checks instead that its listener "tcp" block
# holds exactly one address and that it is the api's RASPUTIN_SECRETSTORE_ADDR,
# read through test/lib/hcl-keys.sh (geekdojo/geekdojo-brain#756). The guard
# decides on those two facts only.
#
# Fails closed. A missing unit, a missing library, no GNU make, a store
# ExecStart with no -config= and an unreadable pin each print one line starting
# FAILED: and exit non-zero before any case runs.
#
# The controls run this same script over scratch copies of the tree with
# API_STORE_WIRING_TREE_ONLY=1, which checks that tree and nothing else.
#
# This is a static test: what systemd does with the lines is
# test/api-store-wiring-functional.sh.
#
# Run:  sh test/api-store-wiring-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
API_UNIT="$OVERLAY/etc/systemd/system/rasputin-api.service"
STORE_UNIT="$OVERLAY/etc/systemd/system/openbao.service"
MK="$ROOT/package/rasputin-api/rasputin-api.mk"
LIB="$ROOT/test/lib"

# The last api release without the store client. cp#462 (the client and the
# selector) is not an ancestor of its tag.
PIN_WITHOUT_CLIENT=2026.10.0
WANT_BACKEND=openbao
WANT_ADDR=https://127.0.0.1:8200

# --- fail closed, before any case (TC-757-04, TC-757-09 e and f) ---------------
for f in "$API_UNIT" "$STORE_UNIT"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing, so the api's store wiring cannot be checked."; exit 1; }
done
for f in checks.sh mk-var.sh unit-directives.sh hcl-keys.sh; do
	[ -f "$LIB/$f" ] || { echo "FAILED: the test library $LIB/$f is missing, so this test cannot run."; exit 1; }
done
command -v make >/dev/null 2>&1 \
	|| { echo "FAILED: GNU make is not on PATH, and the api pin is read from rasputin-api.mk with it."; exit 1; }

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/unit-directives.sh"
. "$ROOT/test/lib/hcl-keys.sh"

D_API=$(directives "$API_UNIT")
D_STORE=$(directives "$STORE_UNIT")

# The store's main config: the first -config= in its ExecStart.
CONFIG=$(printf '%s\n' "$D_STORE" | sed -n 's/^Service|ExecStart=//p' | tr ' \t' '\n\n' \
	| sed -n 's/^-config=//p' | head -1)
[ -n "$CONFIG" ] \
	|| { echo "FAILED: the ExecStart of $STORE_UNIT names no -config=, so the pin guard cannot find the store's config."; exit 1; }
PIN=$(mk_var "$MK" RASPUTIN_API_VERSION 2>/dev/null) \
	|| { echo "FAILED: RASPUTIN_API_VERSION could not be read from $MK with GNU make, so the pin guard cannot decide."; exit 1; }

# --- the checker -----------------------------------------------------------------
#
# values and words D SECTION KEY — the shared lib, test/lib/unit-directives.sh.
# lines_naming D SECTION KEY WORD — the directive lines of KEY that carry WORD,
# joined with |, for a failure message.
lines_naming() {
	printf '%s\n' "$1" | awk -F'|' -v s="$2" -v k="$3=" -v w="$4" '
		$1 == s && index($2, k) == 1 {
			n = split(substr($2, length(k) + 1), a, /[ \t]+/)
			for (i = 1; i <= n; i++) if (a[i] == w) { printf "%s%s", sep, $2; sep = "|"; break }
		}'
}

# assignments D — every assignment in every [Service] Environment= line, split
# the way systemd splits one: words separated by whitespace, a double- or
# single-quoted word unquoted. One "NAME=VALUE<TAB>Environment=<line>" per
# assignment, so a second assignment on another line is counted.
assignments() {
	values "$1" Service Environment | awk '
		{
			s = $0; n = length(s); i = 1
			while (i <= n) {
				c = substr(s, i, 1)
				if (c == " " || c == "\t") { i++; continue }
				w = ""
				while (i <= n) {
					c = substr(s, i, 1)
					if (c == " " || c == "\t") break
					if (c == "\"" || c == "\047") {
						q = c; i++
						while (i <= n && substr(s, i, 1) != q) { w = w substr(s, i, 1); i++ }
						i++
						continue
					}
					w = w c; i++
				}
				print w "\tEnvironment=" s
			}
		}'
}
# assigned A NAME — NAME's values in A, one per line; n_assigned A NAME — how
# many there are; sources A NAME — the lines that assign NAME, joined with |.
assigned() { printf '%s\n' "$1" | awk -F'\t' -v k="$2=" 'index($1, k) == 1 { print substr($1, length(k) + 1) }'; }
n_assigned() { printf '%s\n' "$1" | awk -F'\t' -v k="$2=" 'index($1, k) == 1 { n++ } END { print n + 0 }'; }
sources() { printf '%s\n' "$1" | awk -F'\t' -v k="$2=" 'index($1, k) == 1 { printf "%s%s", sep, $2; sep = "|" }'; }

ASSIGN=$(assignments "$D_API")

# exactly_one NAME WANT — NAME is assigned once in the unit, byte-exact WANT.
exactly_one() {
	_n=$(n_assigned "$ASSIGN" "$1")
	_got=$(assigned "$ASSIGN" "$1")
	_st=1
	[ "$_n" -eq 1 ] && [ "$_got" = "$2" ] && _st=0
	check "TC-757-01 [Service] $1=$2, assigned exactly once" "$_st" \
		"$_n assignment(s), in: $(sources "$ASSIGN" "$1")"
}

echo "1. the api's store settings (TC-757-01)"
exactly_one RASPUTIN_SECRETSTORE_BACKEND "$WANT_BACKEND"
exactly_one RASPUTIN_SECRETSTORE_ADDR "$WANT_ADDR"
_other=$(printf '%s\n' "$ASSIGN" | awk -F'\t' '
	index($1, "RASPUTIN_SECRETSTORE_") == 1 && index($1, "RASPUTIN_SECRETSTORE_BACKEND=") != 1 \
		&& index($1, "RASPUTIN_SECRETSTORE_ADDR=") != 1 { printf "%s%s", sep, $2; sep = "|" }')
check "TC-757-01 no other RASPUTIN_SECRETSTORE_* setting is assigned" "$(yes_if [ -z "$_other" ])" \
	"forbidden line present: $_other"

echo
echo "2. the api pulls the store in and does not depend on it (TC-757-02)"
check "TC-757-02(a) [Unit] Wants= includes openbao.service" \
	"$(yes_if contains "
openbao.service
" "
$(words "$D_API" Unit Wants)
")" "Wants= is: $(values "$D_API" Unit Wants | tr '\n' '|')"
for k in Requires BindsTo Requisite PartOf Upholds; do
	_hit=$(lines_naming "$D_API" Unit "$k" openbao.service)
	check "TC-757-02(b) no $k= on openbao.service" "$(yes_if [ -z "$_hit" ])" "forbidden line present: $_hit"
done
_hit=$(lines_naming "$D_API" Unit Before openbao.service)
check "TC-757-02(c) no Before=openbao.service on the api" "$(yes_if [ -z "$_hit" ])" "forbidden line present: $_hit"
check "TC-757-02(d) openbao.service [Unit] Before= includes rasputin-api.service" \
	"$(yes_if contains "
rasputin-api.service
" "
$(words "$D_STORE" Unit Before)
")" "openbao.service Before= is: $(values "$D_STORE" Unit Before | tr '\n' '|')"

echo
echo "3. the pin guard (TC-757-09)"
if [ ! -f "$OVERLAY$CONFIG" ]; then
	echo "  branch: the store's config $CONFIG is not in the overlay, so the api pin must stay at $PIN_WITHOUT_CLIENT, the last release without the store client"
	check "TC-757-09 RASPUTIN_API_VERSION is $PIN_WITHOUT_CLIENT while $CONFIG is absent (got $PIN)" \
		"$(yes_if [ "$PIN" = "$PIN_WITHOUT_CLIENT" ])" \
		"RASPUTIN_API_VERSION is $PIN but the store's config $CONFIG is not in the overlay. An api with the store client would mint the store's leaf and restart a store with no config, which crash-loops into failed on every control plane, so the pin stays at $PIN_WITHOUT_CLIENT until the config ships."
else
	_want=${WANT_ADDR#https://}
	# hcl_get enforces "exactly one": none, or two in the block (or in two
	# listener "tcp" blocks), is a refusal with its own sentence.
	_addr=$(hcl_get "$OVERLAY$CONFIG" 'listener "tcp"' address 2>&1); _rc=$?
	echo "  branch: the store's config $CONFIG is in the overlay, so its listener must be the api's address ($_want); the pin is $PIN"
	check "TC-756-30 $CONFIG has exactly one listener address" "$(yes_if [ "$_rc" -eq 0 ])" "$_addr"
	_st=1
	[ "$_rc" -eq 0 ] && [ "$_addr" = "$_want" ] && _st=0
	[ "$_rc" -eq 0 ] && check "TC-756-30 the listener address is the api's RASPUTIN_SECRETSTORE_ADDR host and port" "$_st" \
		"the config listens on $_addr but the api's RASPUTIN_SECRETSTORE_ADDR is $WANT_ADDR"
fi

if [ "${API_STORE_WIRING_TREE_ONLY:-0}" = 1 ]; then
	if [ "$fails" -ne 0 ]; then echo "api-store-wiring-test: $fails check(s) FAILED"; exit 1; fi
	echo "api-store-wiring-test: all checks passed"
	exit 0
fi

# --- the shared directives() (TC-757-04, F-757-05) --------------------------------
echo
echo "4. one copy of directives() (TC-757-04)"
for t in seal-key-test.sh store-unit-test.sh; do
	_copy=$(grep -n '^[[:space:]]*directives()' "$ROOT/test/$t" || true)
	check "TC-757-04 test/$t holds no copy of directives()" "$(yes_if [ -z "$_copy" ])" "$_copy"
	check "TC-757-04 test/$t sources test/lib/unit-directives.sh" \
		"$(yes_if grep -q '^\. "\$ROOT/test/lib/unit-directives\.sh"$' "$ROOT/test/$t")"
done

# --- the controls: this script over scratch copies of the tree --------------------
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
SH_BIN=$(command -v sh)
REL_API=board/rasputin/common/rootfs-overlay/etc/systemd/system/rasputin-api.service
REL_STORE=board/rasputin/common/rootfs-overlay/etc/systemd/system/openbao.service
REL_MK=package/rasputin-api/rasputin-api.mk
N=0

# tree — a fresh scratch root holding this script, its libraries, the two units
# and the api's .mk file. Sets T.
tree() {
	N=$((N + 1))
	T="$SCRATCH/t$N"
	mkdir -p "$T/test/lib" "$(dirname "$T/$REL_API")" "$(dirname "$T/$REL_MK")"
	cp "$0" "$T/test/api-store-wiring-test.sh"
	cp "$LIB/checks.sh" "$LIB/mk-var.sh" "$LIB/unit-directives.sh" "$LIB/hcl-keys.sh" "$T/test/lib/"
	cp "$API_UNIT" "$T/$REL_API"
	cp "$STORE_UNIT" "$T/$REL_STORE"
	cp "$MK" "$T/$REL_MK"
}
# edit FILE MODE LINE — in a scratch file: "after:L" puts LINE after the line L,
# "before:L" before it, "replace:L" in its place (an empty LINE deletes L). The
# copy must change, or the control would prove nothing.
edit() {
	_f=$1 _mode=${2%%:*} _anchor=${2#*:} _line=$3
	cp "$_f" "$_f.orig"
	awk -v m="$_mode" -v a="$_anchor" -v l="$_line" '
		$0 == a && m == "before" { print l }
		$0 == a && m == "replace" { if (l != "") print l; next }
		{ print }
		$0 == a && m == "after" { print l }
	' "$_f.orig" >"$_f"
	if cmp -s "$_f" "$_f.orig"; then
		check "the control's edit changed $(basename "$_f") ($2)" 1 "the anchor line is not in the file"
		rm -f "$_f.orig"
		return 1
	fi
	rm -f "$_f.orig"
}
# run_tree [ENV=VALUE ...] — run the scratch tree's copy of this script on that
# tree. Sets OUT and RC.
run_tree() {
	OUT=$(env API_STORE_WIRING_TREE_ONLY=1 "$@" "$SH_BIN" "$T/test/api-store-wiring-test.sh" 2>&1); RC=$?
}
# refused LABEL NEEDLE ... — the run failed, and a FAIL line or the line under
# it names every NEEDLE.
refused() {
	_label=$1; shift
	_fail_text=$(printf '%s\n' "$OUT" | grep -A1 '^  FAIL')
	_st=0
	[ "$RC" -ne 0 ] || _st=1
	for _needle in "$@"; do
		contains "$_needle" "$_fail_text" || _st=1
	done
	_names=""
	for _needle in "$@"; do _names="$_names '$_needle'"; done
	check "$_label: refused, naming$_names" "$_st" \
		"rc=$RC; output: $(printf '%s' "$OUT" | tr '\n' '|')"
	[ -n "$_fail_text" ] && printf '         checker said: %s\n' "$(printf '%s' "$_fail_text" | sed 's/^[[:space:]]*//' | tr '\n' ' ')"
}
# passes LABEL — the run passed.
passes() {
	check "$1: passes" "$(yes_if [ "$RC" -eq 0 ])" "rc=$RC; output: $(printf '%s' "$OUT" | tr '\n' '|')"
}
# failed_closed LABEL NEEDLE — the run exited non-zero, printed exactly one line,
# starting FAILED: and ending in a full stop, that names NEEDLE, and ran no case.
failed_closed() {
	_lines=$(printf '%s\n' "$OUT" | grep -c '')
	_st=1
	[ "$RC" -ne 0 ] && [ "$_lines" -eq 1 ] && contains "$2" "$OUT" \
		&& printf '%s\n' "$OUT" | grep -q '^FAILED: .*\.$' \
		&& ! printf '%s\n' "$OUT" | grep -qE '^  (ok|FAIL) ' && _st=0
	check "$1: exit $RC, one FAILED: sentence naming '$2', no case run" "$_st" "output: $(printf '%s' "$OUT" | tr '\n' '|')"
	printf '         it said: %s\n' "$OUT"
}

REL_CONFIG="board/rasputin/common/rootfs-overlay$CONFIG"
# config — a copy of the shipped store config in the scratch tree, when the
# overlay carries one: the section 5 controls see the tree as shipped, and the
# section 6 controls edit it (geekdojo/geekdojo-brain#756, TC-756-30).
config() {
	[ -f "$OVERLAY$CONFIG" ] || return 0
	mkdir -p "$(dirname "$T/$REL_CONFIG")"
	cp "$OVERLAY$CONFIG" "$T/$REL_CONFIG"
}
echo
echo "5. negative controls: the checker refuses each wrong copy (TC-757-03)"
tree; config; run_tree
passes "TC-757-03 positive control, the unmodified units"
tree; config; edit "$T/$REL_API" after:Wants=openbao.service 'Requires=openbao.service' \
	&& { run_tree; refused "TC-757-03 Requires=openbao.service added" 'Requires=openbao.service'; }
tree; config; edit "$T/$REL_API" after:Wants=openbao.service 'BindsTo=openbao.service' \
	&& { run_tree; refused "TC-757-03 BindsTo=openbao.service added" 'BindsTo=openbao.service'; }
tree; config; edit "$T/$REL_API" replace:Wants=openbao.service '' \
	&& { run_tree; refused "TC-757-03 Wants=openbao.service removed" 'Wants= includes openbao.service'; }
tree; config; edit "$T/$REL_API" replace:Environment=RASPUTIN_SECRETSTORE_BACKEND=openbao \
	'Environment=RASPUTIN_SECRETSTORE_BACKEND=OpenBao' \
	&& { run_tree; refused "TC-757-03 BACKEND=OpenBao" 'Environment=RASPUTIN_SECRETSTORE_BACKEND=OpenBao'; }
tree; config; edit "$T/$REL_API" replace:Environment=RASPUTIN_SECRETSTORE_BACKEND=openbao \
	'Environment="RASPUTIN_SECRETSTORE_BACKEND=openbao "' \
	&& { run_tree; refused "TC-757-03 a quoted trailing space" 'Environment="RASPUTIN_SECRETSTORE_BACKEND=openbao "'; }
tree; config; edit "$T/$REL_API" after:Environment=RASPUTIN_SECRETSTORE_ADDR=https://127.0.0.1:8200 \
	'Environment=RASPUTIN_SECRETSTORE_CA_FILE=/x' \
	&& { run_tree; refused "TC-757-03 an extra RASPUTIN_SECRETSTORE_CA_FILE" 'Environment=RASPUTIN_SECRETSTORE_CA_FILE=/x'; }
tree; config; edit "$T/$REL_API" before:EnvironmentFile=-/var/lib/rasputin/node.env \
	'Environment=RASPUTIN_DATA_DIR=/var/lib/rasputin RASPUTIN_SECRETSTORE_BACKEND=mock' \
	&& { run_tree; refused "TC-757-03 a second, later BACKEND assignment on another line" \
		'Environment=RASPUTIN_DATA_DIR=/var/lib/rasputin RASPUTIN_SECRETSTORE_BACKEND=mock'; }
tree; config; edit "$T/$REL_STORE" replace:Before=rasputin-api.service '' \
	&& { run_tree; refused "TC-757-03 the store's Before=rasputin-api.service removed" 'Before= includes rasputin-api.service'; }

echo
echo "6. the pin guard's controls (TC-757-09)"
ADDR_LINE='  address = "127.0.0.1:8200"'
MOVED=2099.01.0
move_pin() { edit "$T/$REL_MK" "replace:RASPUTIN_API_VERSION = $PIN" "RASPUTIN_API_VERSION = $MOVED"; }
tree; move_pin && { run_tree; refused "TC-757-09(a) the pin moved to $MOVED with no config" \
	"$MOVED" "$CONFIG" "crash-loops"; }
tree; config; edit "$T/$REL_CONFIG" "replace:$ADDR_LINE" '  address = "127.0.0.1:8201"' \
	&& { run_tree; refused "TC-756-30 (TC-757-09(b)) the shipped config with its listener moved to 127.0.0.1:8201" \
		'127.0.0.1:8201' "$WANT_ADDR"; }
tree; config; edit "$T/$REL_CONFIG" "after:$ADDR_LINE" '  address = "127.0.0.1:8201"' \
	&& { run_tree; refused "TC-756-30 (TC-757-09(c)) the shipped config with a second address in its listener" \
		'exactly one listener address' 'has address 2 times in the listener "tcp" block'; }
tree; config; edit "$T/$REL_CONFIG" "replace:$ADDR_LINE" '' \
	&& edit "$T/$REL_CONFIG" 'before:listener "tcp" {' 'address = "127.0.0.1:8200"' \
	&& { run_tree; refused "TC-756-30 the shipped config with its address at the top level only" \
		'exactly one listener address' 'has no address in the listener "tcp" block'; }
tree; config; move_pin && { run_tree; passes "TC-756-30 (TC-757-09(d)) the shipped config, with the pin moved to $MOVED"; }
tree; _x=$(values "$D_STORE" Service ExecStart)
edit "$T/$REL_STORE" "replace:ExecStart=$_x" 'ExecStart=/usr/bin/bao server' \
	&& { run_tree; failed_closed "TC-757-09(e) the store's ExecStart has no -config=" 'names no -config='; }
tree; edit "$T/$REL_MK" "replace:RASPUTIN_API_VERSION = $PIN" '' \
	&& { run_tree; failed_closed "TC-757-09(f) RASPUTIN_API_VERSION undefined" 'RASPUTIN_API_VERSION could not be read'; }
tree; rm -f "$T/$REL_MK"; run_tree
failed_closed "TC-757-09(f) rasputin-api.mk missing" 'RASPUTIN_API_VERSION could not be read'

echo
echo "7. the test fails closed (TC-757-04)"
tree; rm -f "$T/$REL_API"; run_tree
failed_closed "TC-757-04(a) the api unit missing" 'rasputin-api.service is missing'
tree; rm -f "$T/test/lib/unit-directives.sh"; run_tree
failed_closed "TC-757-04(b) test/lib/unit-directives.sh missing" 'unit-directives.sh is missing'
# No make: a PATH holding only dirname, which the script needs before it looks
# for make.
NOMAKE="$SCRATCH/nomake"
mkdir -p "$NOMAKE"
ln -s "$(command -v dirname)" "$NOMAKE/dirname"
tree; run_tree PATH="$NOMAKE"
failed_closed "TC-757-04(c) GNU make absent from PATH" 'GNU make is not on PATH'

echo
if [ "$fails" -ne 0 ]; then echo "api-store-wiring-test: $fails check(s) FAILED"; exit 1; fi
echo "api-store-wiring-test: all checks passed"
