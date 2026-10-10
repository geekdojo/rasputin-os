#!/bin/sh
# Tests for package/openbao, the pinned secrets-store binary
# (geekdojo/geekdojo-brain#798). Nothing on a pull request builds the image, so
# the three things in the package that can be wrong without anything noticing
# until a release build, or never, are pinned here:
#
#   * the per-arch tarball map. An architecture it does not know must fail the
#     build when the store is on, and only then; an empty GOARCH would ask for
#     openbao_2.7.1_linux_.tar.gz and fail late with a download error that
#     names nothing useful;
#   * openbao.hash. Every tarball the map can ask for, and LICENSE, need exactly
#     one sha256 line. Buildroot's check-hash refuses a missing hash on its own
#     (support/download/check-hash), so what is pinned here is the coverage;
#   * the MPL-2.0 source notice. It is a hand-written file on purpose, so a
#     version bump that forgets it ships a notice naming the wrong release. It
#     must name the pinned version in its header and its tag URL, and no other.
#
# The .mk file is evaluated with REAL GNU make, through test/lib/mk-var.sh, so
# the values compared are the ones Buildroot would see. No make is a failure,
# not a skip.
#
# What this does NOT prove: download, strip and install, or that mkusers
# applies the uid. The image build and test/update-smoke.sh cover those.
#
# Run:  sh test/openbao-package-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PKG="$ROOT/package/openbao"
MK="$PKG/openbao.mk"
HASH="$PKG/openbao.hash"
NOTICE="$PKG/SOURCE"
. "$ROOT/test/lib/mk-var.sh"

for f in "$MK" "$HASH" "$NOTICE"; do
	[ -f "$f" ] || { echo "FAIL — missing: $f"; exit 1; }
done
case "$(make --version 2>/dev/null)" in
	"GNU Make"*) ;;
	*) echo "FAIL — GNU make is not on PATH. This suite evaluates openbao.mk with it and never skips."; exit 1 ;;
esac

fails=0
check() { # check LABEL GOT WANT
	if [ "$2" = "$3" ]; then echo "ok   — $1 ($2)"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
contains() { # contains LABEL HAYSTACK NEEDLE
	case "$2" in
		*"$3"*) echo "ok   — $1" ;;
		*) echo "FAIL — $1: '$3' not in: $2"; fails=$((fails + 1)) ;;
	esac
}

has_line_ending() { # has_line_ending LABEL TEXT LINE — some line of TEXT is LINE
	# exactly, after make's "<file>:<line>: " location prefix.
	_found=0
	while IFS= read -r _l; do
		case "$_l" in *": $3") _found=1 ;; esac
	done <<EOF_LINES
$2
EOF_LINES
	if [ "$_found" = 1 ]; then echo "ok   — $1"
	else echo "FAIL — $1: no line ending ': $3' in: $2"; fails=$((fails + 1)); fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ── the checks the suite applies to the real files, as functions so the
#    negative cases can run them against broken copies ─────────────────────────

# check_hash HASHFILE TARBALL... — every name, and LICENSE, has exactly one
# "sha256 <64 hex> <name>" line. Prints one sentence per problem; status 1 if any.
check_hash() {
	_hf="$1"; shift
	_bad=0
	for _name in "$@" LICENSE; do
		_n=$(grep -cE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+$(printf '%s' "$_name" | sed 's/\./\\./g')\$" "$_hf")
		if [ "$_n" -ne 1 ]; then
			echo "openbao.hash has $_n sha256 lines for $_name, and needs exactly one."
			_bad=1
		fi
	done
	return "$_bad"
}

# check_notice SOURCEFILE PINNED — the notice names PINNED in its header
# statement and its tag URL, and names no other version. Prints the sentence
# for the first problem; status 1 on any.
check_notice() {
	_sf="$1"; _pin="$2"
	_found=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$_sf" | sort -u)
	if [ -z "$_found" ]; then
		echo "SOURCE does not name the pinned OpenBao version $_pin."
		return 1
	fi
	for _v in $_found; do
		if [ "$_v" != "$_pin" ]; then
			echo "SOURCE names OpenBao $_v, but openbao.mk pins $_pin."
			return 1
		fi
	done
	if ! grep -qxF "OpenBao $_pin is distributed under the Mozilla Public License 2.0." "$_sf" \
		|| ! grep -qF "https://github.com/openbao/openbao/tree/v$_pin" "$_sf"; then
		echo "SOURCE does not name the pinned OpenBao version $_pin."
		return 1
	fi
	return 0
}

# map_row LABEL WANT_STATUS WANT_SOURCE NAME=VALUE... — evaluate OPENBAO_SOURCE
# with the given Buildroot config. WANT_SOURCE is the expected value on success,
# or the expected stderr substring on failure.
map_row() {
	_label="$1"; _want_rc="$2"; _want="$3"; shift 3
	_out=$(mk_var "$MK" OPENBAO_SOURCE "$@" 2> "$TMP/err"); _rc=$?
	_err=$(cat "$TMP/err")
	if [ "$_want_rc" = 0 ]; then
		check "$_label: exit status" "$_rc" 0
		check "$_label: OPENBAO_SOURCE" "$_out" "$_want"
	else
		check "$_label: exit status is non-zero" "$([ "$_rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
		check "$_label: nothing on stdout" "$_out" ""
		has_line_ending "$_label: stderr carries the line the reader sees" "$_err" "$_want"
		case "$_err" in
			*"openbao.hash.."*) echo "FAIL — $_label: stderr has a doubled full stop (openbao.hash..): $_err"; fails=$((fails + 1)) ;;
			*) echo "ok   — $_label: no doubled full stop (openbao.hash..)" ;;
		esac
	fi
}

PIN=$(mk_var "$MK" OPENBAO_VERSION) || { echo "FAIL — Could not read the pin, so nothing below has anything to compare against."; exit 1; }
echo "openbao.mk pins $PIN"

echo "── per-arch tarball map"
# TC-798-01
map_row "TC-798-01 aarch64" 0 "openbao_${PIN}_linux_arm64.tar.gz" BR2_PACKAGE_OPENBAO=y BR2_aarch64=y BR2_ARCH=aarch64
# TC-798-02
map_row "TC-798-02 x86_64" 0 "openbao_${PIN}_linux_amd64.tar.gz" BR2_PACKAGE_OPENBAO=y BR2_x86_64=y BR2_ARCH=x86_64
# TC-798-03: an architecture the map does not know fails the build, with a
# sentence naming the arch and the fix (F-798-05), exactly as the reader sees
# it: make appends ".  Stop.", so one full stop, never "openbao.hash.."
# (F-798-13).
for a in arm riscv; do
	map_row "TC-798-03 package on, $a" 1 \
		"*** OpenBao has no release tarball mapped for the target architecture $a. Add the architecture to the map in package/openbao/openbao.mk and its sha256 to openbao.hash.  Stop." \
		BR2_PACKAGE_OPENBAO=y "BR2_$a=y" "BR2_ARCH=$a"
done
# TC-798-04: with the store off, an unmapped arch still evaluates cleanly, so a
# defconfig without the store builds anywhere.
_out=$(mk_var "$MK" OPENBAO_VERSION BR2_arm=y BR2_ARCH=arm 2> "$TMP/err"); _rc=$?
check "TC-798-04 package off, arm: exit status" "$_rc" 0
check "TC-798-04 package off, arm: no error on stderr" "$(cat "$TMP/err")" ""

echo "── openbao.hash covers every mapped tarball and LICENSE"
# TC-798-05
ARM=$(mk_var "$MK" OPENBAO_SOURCE BR2_PACKAGE_OPENBAO=y BR2_aarch64=y BR2_ARCH=aarch64)
AMD=$(mk_var "$MK" OPENBAO_SOURCE BR2_PACKAGE_OPENBAO=y BR2_x86_64=y BR2_ARCH=x86_64)
_msg=$(check_hash "$HASH" "$ARM" "$AMD"); _rc=$?
check "TC-798-05 the real openbao.hash passes${_msg:+: $_msg}" "$_rc" 0
grep -v " $ARM\$" "$HASH" > "$TMP/hash-removed"
_msg=$(check_hash "$TMP/hash-removed" "$ARM" "$AMD"); _rc=$?
check "TC-798-05 a copy without the arm64 line fails" "$_rc" 1
contains "TC-798-05 and says why" "$_msg" "openbao.hash has 0 sha256 lines for $ARM, and needs exactly one."
{ cat "$HASH"; grep " $ARM\$" "$HASH"; } > "$TMP/hash-dup"
_msg=$(check_hash "$TMP/hash-dup" "$ARM" "$AMD"); _rc=$?
check "TC-798-05 a copy with the arm64 line duplicated fails" "$_rc" 1
contains "TC-798-05 and says why" "$_msg" "openbao.hash has 2 sha256 lines for $ARM, and needs exactly one."

echo "── the source notice agrees with the pin"
# TC-798-06
_msg=$(check_notice "$NOTICE" "$PIN"); _rc=$?
check "TC-798-06 the real SOURCE passes${_msg:+: $_msg}" "$_rc" 0
check "TC-798-06 header statement names the pin" \
	"$(grep -cxF "OpenBao $PIN is distributed under the Mozilla Public License 2.0." "$NOTICE")" 1
check "TC-798-06 tag URL names the pin" \
	"$(grep -cF "https://github.com/openbao/openbao/tree/v$PIN" "$NOTICE")" 1
check "TC-798-06 every x.y.z in SOURCE is the pin" \
	"$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$NOTICE" | sort -u)" "$PIN"
# A version that differs from the pin, built from it, so the negative cases
# stay meaningful whatever the pin becomes.
OTHER="${PIN%.*}.$(( ${PIN##*.} + 1 ))"
# TC-798-07: only the header version changed, then only the URL tag changed.
sed "s/^OpenBao $PIN is/OpenBao $OTHER is/" "$NOTICE" > "$TMP/notice-header"
sed "s#/tree/v$PIN#/tree/v$OTHER#" "$NOTICE" > "$TMP/notice-url"
for c in header url; do
	check "TC-798-07 the $c copy differs from SOURCE in one line" \
		"$(diff "$NOTICE" "$TMP/notice-$c" | grep -c '^>')" 1
	_msg=$(check_notice "$TMP/notice-$c" "$PIN"); _rc=$?
	check "TC-798-07 $c version changed: exit status" "$_rc" 1
	check "TC-798-07 $c version changed: message" "$_msg" "SOURCE names OpenBao $OTHER, but openbao.mk pins $PIN."
done
# TC-798-08 (F-798-04): a notice that names no version at all is refused, not
# passed because nothing in it disagrees.
sed -E 's/v?[0-9]+\.[0-9]+\.[0-9]+//g' "$NOTICE" > "$TMP/notice-none"
check "TC-798-08 the copy names no x.y.z" "$(grep -cE '[0-9]+\.[0-9]+\.[0-9]+' "$TMP/notice-none")" 0
_msg=$(check_notice "$TMP/notice-none" "$PIN"); _rc=$?
check "TC-798-08 no version: exit status" "$_rc" 1
check "TC-798-08 no version: message" "$_msg" "SOURCE does not name the pinned OpenBao version $PIN."

echo "── mk_var fails closed"
# TC-798-09: one row per input. Each failure: non-zero, nothing on stdout, a
# capitalised sentence ending in a full stop on stderr.
check "TC-798-09 reads OPENBAO_VERSION" "$(mk_var "$MK" OPENBAO_VERSION)" 2.7.1
printf 'OPENBAO_EMPTY =\n' > "$TMP/empty.mk"
mkvar_fails() { # mkvar_fails LABEL WANT_STDERR -- then the call runs in a subshell
	_label="$1"; _want="$2"; shift 2
	_out=$("$@" 2> "$TMP/err"); _rc=$?
	_err=$(cat "$TMP/err")
	check "TC-798-09 $_label: exit status is non-zero" "$([ "$_rc" -ne 0 ] && echo non-zero || echo 0)" non-zero
	check "TC-798-09 $_label: nothing on stdout" "$_out" ""
	check "TC-798-09 $_label: stderr" "$_err" "$_want"
	case "$_err" in
		[A-Z]*.) echo "ok   — TC-798-09 $_label: stderr is a capitalised sentence ending in a full stop" ;;
		*) echo "FAIL — TC-798-09 $_label: stderr is not a capitalised sentence ending in a full stop: $_err"; fails=$((fails + 1)) ;;
	esac
}
mkvar_fails "missing file" \
	"Could not read OPENBAO_VERSION from $TMP/absent.mk. The file does not exist." \
	mk_var "$TMP/absent.mk" OPENBAO_VERSION
mkvar_fails "undefined variable" \
	"Could not read OPENBAO_NO_SUCH_VAR from $MK. It is undefined or empty." \
	mk_var "$MK" OPENBAO_NO_SUCH_VAR
mkvar_fails "empty variable" \
	"Could not read OPENBAO_EMPTY from $TMP/empty.mk. It is undefined or empty." \
	mk_var "$TMP/empty.mk" OPENBAO_EMPTY
no_make() ( PATH="$TMP/no-such-dir"; mk_var "$MK" OPENBAO_VERSION )
mkvar_fails "no make on PATH" \
	"Could not read OPENBAO_VERSION from $MK. GNU make is not on PATH." \
	no_make
# F-798-15: the helper's two remaining branches.
mkvar_fails "no variable name" \
	"The mk_var helper needs a .mk file and a variable name." \
	mk_var "$MK"
mk_var "$MK" > /dev/null 2>&1; _rc=$?
check "TC-798-09 no variable name: exit status" "$_rc" 2
mkdir "$TMP/not-gnu"
printf '#!/bin/sh\necho "bmake 20240711"\n' > "$TMP/not-gnu/make"
chmod +x "$TMP/not-gnu/make"
not_gnu_make() ( PATH="$TMP/not-gnu"; mk_var "$MK" OPENBAO_VERSION )
mkvar_fails "make on PATH is not GNU make" \
	"Could not read OPENBAO_VERSION from $MK. The make on PATH is not GNU make." \
	not_gnu_make

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all OpenBao package checks passed"
