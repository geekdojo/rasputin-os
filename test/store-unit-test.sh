#!/bin/sh
# Static assertions on the secrets store's unit, openbao.service
# (geekdojo/geekdojo-brain#755).
#
# Why. Every line of the unit is a decision with a reason recorded in it, and
# almost every way to get one wrong is silent: a watchdog the store never pets
# kills it every 30 s, a network-online dependency stalls an appliance store
# that listens only on 127.0.0.1, a MemoryHigh stalls it with no kill and no
# restart, an [Install] section gets it enabled on every image by preset-all
# before its config exists. So each directive is pinned at its exact value and
# in its section, the forbidden ones are refused, and the unit is tied to the
# files it depends on: the tmpfiles lines that create its directories (#754)
# and the static user package/openbao declares (S7, read with real GNU make).
#
# Negative controls. The checker is run over temp copies of the unit with one
# bad line injected each, and must refuse every one, naming the line. That is
# what shows the "fails if ..." claims are true and not just untested.
#
# This is a static test: it reads what ships. What systemd and bao do with it
# is test/store-unit-functional.sh.
#
# Run:  sh test/store-unit-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
UNIT="$OVERLAY/etc/systemd/system/openbao.service"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
MK="$ROOT/package/openbao/openbao.mk"

# Fail closed, before anything else: a missing input or tool is a failure with
# a sentence, never a pass over nothing (TC-755-07).
for f in "$UNIT" "$TMPFILES" "$POSTBUILD" "$MK"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing, so the store unit cannot be checked."; exit 1; }
done
command -v make >/dev/null 2>&1 \
	|| { echo "FAILED: GNU make is not on PATH, and the openbao user is read from openbao.mk with it."; exit 1; }

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"

# The static user, from the package (S7). Fields: name uid group gid ...
USERS=$(mk_var "$MK" OPENBAO_USERS) || { echo "FAILED: could not read OPENBAO_USERS from $MK."; exit 1; }
# Split into fields on purpose; -f because the fifth field is a literal *.
set -f
# shellcheck disable=SC2086
set -- $USERS
set +f
BAO_USER=$1 BAO_UID=$2 BAO_GROUP=$3 BAO_GID=$4
[ -n "${BAO_GID:-}" ] || { echo "FAILED: OPENBAO_USERS ('$USERS') has fewer than four fields."; exit 1; }

# --- the checker -------------------------------------------------------------
#
# directives UNIT — one "Section|Key=Value" line per directive, and
# values D SECTION KEY — every value KEY has in SECTION (the shared lib).
. "$ROOT/test/lib/unit-directives.sh"
count() { printf '%s\n' "$1" | grep -c "^$2|$3=" ; }
# bytes N[K|M|G|KiB|MiB|GiB] — systemd's and Go's binary suffixes, in bytes.
bytes() {
	case "$1" in
		*KiB) echo $(( ${1%KiB} * 1024 )) ;;
		*MiB) echo $(( ${1%MiB} * 1024 * 1024 )) ;;
		*GiB) echo $(( ${1%GiB} * 1024 * 1024 * 1024 )) ;;
		*K) echo $(( ${1%K} * 1024 )) ;;
		*M) echo $(( ${1%M} * 1024 * 1024 )) ;;
		*G) echo $(( ${1%G} * 1024 * 1024 * 1024 )) ;;
		*[!0-9]*|'') return 1 ;;
		*) echo "$1" ;;
	esac
}

# verify UNIT — prints an ok or FAIL line per assertion and returns the number
# of failures (capped at 1 for the exit status). Run in a subshell so its
# $fails is its own.
verify() (
	fails=0
	U=$1
	NAME=$(basename "$U")
	D=$(directives "$U")

	# exactly SECTION KEY VALUE — KEY appears once in SECTION, with VALUE.
	exactly() {
		_got=$(values "$D" "$1" "$2")
		_st=1
		[ "$(count "$D" "$1" "$2")" -eq 1 ] && [ "$_got" = "$3" ] && _st=0
		check "[$1] $2=$3" "$_st" "got: $(printf '%s' "$_got" | tr '\n' '|')"
	}
	# includes SECTION KEY VALUE — one of KEY's values in SECTION is VALUE.
	includes() {
		check "[$1] $2=$3" "$(yes_if contains "
$3
" "
$(values "$D" "$1" "$2")
")" "not among: $(values "$D" "$1" "$2" | tr '\n' '|')"
	}
	# forbidden LABEL EREGEX — no directive line matches; the failure names it.
	forbidden() {
		_hit=$(printf '%s\n' "$D" | grep -E "$2" || true)
		check "no $1" "$(yes_if [ -z "$_hit" ])" "forbidden line present: $(printf '%s' "$_hit" | tr '\n' '|')"
	}

	echo "  -- directives (TC-755-01)"
	exactly Unit Description 'OpenBao secrets store'
	exactly Unit RequiresMountsFor /var/lib/rasputin
	exactly Unit After rasputin-firstboot.service
	exactly Unit Before rasputin-api.service
	check "[Unit] exactly four ConditionPathExists lines" \
		"$(yes_if [ "$(count "$D" Unit ConditionPathExists)" -eq 4 ])" "got $(count "$D" Unit ConditionPathExists)"
	includes Unit ConditionPathExists /var/lib/rasputin/role.controlplane
	includes Unit ConditionPathExists /var/lib/rasputin/trust/store-ca.pem
	includes Unit ConditionPathExists /var/lib/rasputin/tls/openbao-server/leaf.pem
	includes Unit ConditionPathExists /var/lib/rasputin/tls/openbao-server/leaf.key
	exactly Service Type notify
	exactly Service NotifyAccess main
	exactly Service User openbao
	exactly Service Group openbao
	exactly Service ExecStart \
		'/usr/bin/bao server -config=/etc/rasputin/openbao/openbao.hcl -config=/run/credentials/openbao.service/seal.hcl'
	check "[Service] exactly five LoadCredential lines" \
		"$(yes_if [ "$(count "$D" Service LoadCredential)" -eq 5 ])" "got $(count "$D" Service LoadCredential)"
	includes Service LoadCredential seal-key:/var/lib/rasputin/openbao-seal/seal-key
	includes Service LoadCredential seal.hcl:/var/lib/rasputin/openbao-seal/seal.hcl
	includes Service LoadCredential store-ca.pem:/var/lib/rasputin/trust/store-ca.pem
	includes Service LoadCredential server.pem:/var/lib/rasputin/tls/openbao-server/leaf.pem
	includes Service LoadCredential server.key:/var/lib/rasputin/tls/openbao-server/leaf.key
	exactly Service Restart always
	exactly Service ProtectSystem strict
	exactly Service ReadWritePaths '/var/lib/rasputin/openbao /var/lib/rasputin/openbao-audit'
	exactly Service PrivateTmp yes
	exactly Service PrivateDevices yes
	exactly Service NoNewPrivileges yes
	exactly Service CapabilityBoundingSet ''
	exactly Service LimitCORE 0
	exactly Service MemoryMax 128M
	exactly Service MemorySwapMax 0
	exactly Service OOMScoreAdjust -999
	exactly Service Environment GOMEMLIMIT=60MiB
	_sections=$(printf '%s\n' "$D" | cut -d'|' -f1 | sort -u | tr '\n' ' ')
	check "only [Unit] and [Service] sections" "$(yes_if [ "$_sections" = "Service Unit " ])" "got: $_sections"

	echo "  -- forbidden directives (TC-755-02, TC-755-03)"
	forbidden "WatchdogSec (bao never pets a watchdog)" '\|WatchdogSec='
	forbidden "network-online dependency (the store listens on 127.0.0.1)" '\|[A-Za-z]+=.*network-online\.target'
	forbidden "MemoryHigh (S6: it stalls the store with no kill)" '\|MemoryHigh='
	forbidden "LogRateLimit override (S11; ignored per unit)" '\|LogRateLimit[A-Za-z]*='
	forbidden "RestartSec (ARCH-FACTS: no chosen duration)" '\|RestartSec='
	forbidden "StartLimit setting (ARCH-FACTS: no chosen duration)" '\|StartLimit[A-Za-z]*='
	forbidden "AmbientCapabilities (no capabilities at all)" '\|AmbientCapabilities='
	_install=$(grep -nE '^[[:space:]]*\[Install\]' "$U" || true)
	check "no [Install] section (installed, not wanted)" "$(yes_if [ -z "$_install" ])" \
		"forbidden line present: $_install"

	echo "  -- ties to #754 and S7 (TC-755-04)"
	check "User= is OPENBAO_USERS' name ($BAO_USER)" "$(yes_if [ "$(values "$D" Service User)" = "$BAO_USER" ])"
	check "Group= is OPENBAO_USERS' group ($BAO_GROUP)" "$(yes_if [ "$(values "$D" Service Group)" = "$BAO_GROUP" ])"
	for p in $(values "$D" Service ReadWritePaths); do
		check "ReadWritePaths $p has a tmpfiles d line at 0700 owned by OPENBAO_USERS' uid and gid" \
			"$(yes_if awk -v p="$p" -v u="$BAO_UID" -v g="$BAO_GID" \
				'$1 == "d" && $2 == p && $3 == "0700" && $4 == u && $5 == g { found = 1 } END { exit !found }' "$TMPFILES")" \
			"no 'd $p 0700 $BAO_UID $BAO_GID' line in $TMPFILES"
	done
	_sources=$(values "$D" Service LoadCredential | sed 's/^[^:]*://')
	for s in $_sources; do
		_dir=$(dirname "$s")
		check "credential source $s sits in a tmpfiles-declared 0700 root directory" \
			"$(yes_if awk -v p="$_dir" \
				'$1 == "d" && $2 == p && $3 == "0700" && $4 == "root" && $5 == "root" { found = 1 } END { exit !found }' "$TMPFILES")" \
			"no 'd $_dir 0700 root root' line in $TMPFILES"
	done
	_seal_name=$(values "$D" Service LoadCredential | awk -F: '$2 ~ /\/seal\.hcl$/ { print $1 }')
	_want_seal="/run/credentials/$NAME/$_seal_name"
	_st=1
	[ -n "$_seal_name" ] && contains " -config=$_want_seal" " $(values "$D" Service ExecStart)" && _st=0
	check "ExecStart's seal fragment is $_want_seal (this unit's credential directory and the seal.hcl credential's name)" \
		"$_st" "ExecStart: $(values "$D" Service ExecStart)"
	for c in $(values "$D" Unit ConditionPathExists); do
		[ "$c" = /var/lib/rasputin/role.controlplane ] && continue
		check "condition $c is a LoadCredential source" "$(yes_if contains "
$c
" "
$_sources
")"
	done
	_seal_conditions=$(values "$D" Unit ConditionPathExists | grep '/openbao-seal/' || true)
	check "no condition names the seal key or the seal fragment (absent seal material fails, never skips)" \
		"$(yes_if [ -z "$_seal_conditions" ])" "got: $_seal_conditions"

	echo "  -- memory (TC-755-05)"
	_gml=$(values "$D" Service Environment | sed -n 's/^GOMEMLIMIT=//p')
	_gml_b=$(bytes "$_gml" 2>/dev/null || echo)
	_max_b=$(bytes "$(values "$D" Service MemoryMax)" 2>/dev/null || echo)
	_st=1
	[ -n "$_gml_b" ] && [ -n "$_max_b" ] && [ "$_gml_b" -lt "$_max_b" ] && _st=0
	check "GOMEMLIMIT ($_gml_b bytes) is below MemoryMax ($_max_b bytes)" \
		"$_st" "GOMEMLIMIT=$_gml MemoryMax=$(values "$D" Service MemoryMax)"

	[ "$fails" -eq 0 ]
)

# --- the shipped unit ----------------------------------------------------------
echo "1. the shipped unit"
verify "$UNIT"; rc=$?
check "the shipped openbao.service passes every check" "$rc"

echo
echo "2. not wanted (TC-755-06)"
wants=$(find "$OVERLAY" -path '*.wants/openbao.service' 2>/dev/null)
check "no *.wants/openbao.service link in the overlay" "$(yes_if [ -z "$wants" ])" "$wants"
linked=$(grep -n 'openbao\.service' "$POSTBUILD" || true)
check "post-build.sh links nothing to openbao.service" "$(yes_if [ -z "$linked" ])" "$linked"

# --- negative controls ---------------------------------------------------------
echo
echo "3. negative controls: the checker refuses each injected line (TC-755-02..05)"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
# refuses DESCRIPTION SECTION LINE [NEEDLE] — a copy of the unit, named as the
# shipped one, with LINE added to SECTION (for SECTION "new", appended as its
# own section; for SECTION "replace:OLD", put in place of the line OLD), must
# fail verify, and the output must name NEEDLE (the line itself by default).
refuses() {
	mkdir -p "$SCRATCH/c"
	_copy="$SCRATCH/c/openbao.service"
	case "$2" in
		new) { cat "$UNIT"; printf '%s\n' "$3"; } >"$_copy" ;;
		replace:*) awk -v o="${2#replace:}" -v l="$3" '$0 == o { print l; next } { print }' "$UNIT" >"$_copy" ;;
		*) awk -v s="[$2]" -v l="$3" '{ print } $0 == s { print l }' "$UNIT" >"$_copy" ;;
	esac
	cmp -s "$UNIT" "$_copy" && { check "$1: the injection changed the copy" 1 "nothing was injected"; return; }
	_out=$(verify "$_copy"); _rc=$?
	_needle=${4:-$3}
	_fail_line=$(printf '%s\n' "$_out" | grep -A1 'FAIL' | grep -F -e "$_needle" | head -1)
	_st=1
	[ "$_rc" -ne 0 ] && [ -n "$_fail_line" ] && _st=0
	check "$1: refused, naming '$_needle'" "$_st" \
		"rc=$_rc; output: $(printf '%s' "$_out" | grep -A1 FAIL | tr '\n' '|')"
	[ -n "$_fail_line" ] && printf '         checker said: %s\n' "$(printf '%s' "$_fail_line" | sed 's/^[[:space:]]*//')"
	rm -f "$_copy"
}
refuses "WatchdogSec=30" Service 'WatchdogSec=30'
refuses "After=network-online.target" Unit 'After=network-online.target'
refuses "Wants=network-online.target" Unit 'Wants=network-online.target'
refuses "Requires=network-online.target" Unit 'Requires=network-online.target'
refuses "MemoryHigh=100M" Service 'MemoryHigh=100M'
refuses "LogRateLimitIntervalSec=0" Service 'LogRateLimitIntervalSec=0'
refuses "RestartSec=5" Service 'RestartSec=5'
refuses "StartLimitBurst=3" Unit 'StartLimitBurst=3'
refuses "AmbientCapabilities=CAP_IPC_LOCK" Service 'AmbientCapabilities=CAP_IPC_LOCK'
refuses "[Install] WantedBy=multi-user.target" new '[Install]
WantedBy=multi-user.target' '[Install]'
refuses "ReadWritePaths widened to /var/lib/rasputin" \
	'replace:ReadWritePaths=/var/lib/rasputin/openbao /var/lib/rasputin/openbao-audit' \
	'ReadWritePaths=/var/lib/rasputin /var/lib/rasputin/openbao /var/lib/rasputin/openbao-audit' \
	"ReadWritePaths /var/lib/rasputin has"
refuses "GOMEMLIMIT=200MiB, above MemoryMax" 'replace:Environment=GOMEMLIMIT=60MiB' \
	'Environment=GOMEMLIMIT=200MiB' 'GOMEMLIMIT (209715200 bytes) is below MemoryMax'

# --- the test fails closed (TC-755-07) -------------------------------------------
echo
echo "4. the test fails closed"
# A root without the unit: this script and its libraries, nothing else.
mkdir -p "$SCRATCH/root/test/lib"
cp "$0" "$SCRATCH/root/test/store-unit-test.sh"
cp "$ROOT/test/lib/checks.sh" "$ROOT/test/lib/mk-var.sh" "$SCRATCH/root/test/lib/"
SH_BIN=$(command -v sh)
out=$("$SH_BIN" "$SCRATCH/root/test/store-unit-test.sh" 2>&1); rc=$?
check "with no unit file the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no unit file the message names the file" "$(yes_if contains 'openbao.service is missing' "$out")" "$out"
printf '         it said: %s\n' "$out"
# No make on PATH: a stub directory holding only dirname, which the script
# needs before it looks for make.
NOMAKE="$SCRATCH/nomake"
mkdir -p "$NOMAKE"
ln -s "$(command -v dirname)" "$NOMAKE/dirname"
out=$(PATH="$NOMAKE" "$SH_BIN" "$0" 2>&1); rc=$?
check "with no make the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no make the message names GNU make" "$(yes_if contains 'GNU make is not on PATH' "$out")" "$out"
printf '         it said: %s\n' "$out"

echo
if [ "$fails" -ne 0 ]; then echo "store-unit-test: $fails check(s) FAILED"; exit 1; fi
echo "store-unit-test: all checks passed"
