#!/bin/sh
#
# Tests for scripts/compress-image.sh, which makes each release's .img.xz as
# one xz stream so slot B's copy of slot A costs no download
# (geekdojo/geekdojo-brain#969, TC-969-22 to TC-969-26).
#
# Why. A wrong setting here does not fail anything visible: a shrunk
# dictionary or a multi-block file still decodes, and the asset is just twice
# the size again. And a file that does not decode to the built image must never
# reach the release. So the happy path runs the real xz on a fixture whose
# second half repeats its first, and checks the size, the layout xz reads back
# and the round trip. Every refusal is a row, through a stub xz on PATH that
# breaks one mode and hands the rest to the real xz, and each refusal must
# leave no output and no .tmp behind for the release job to upload.
#
# The slot fit (TC-969-26) is here too: the one-stream trick only works while
# each A/B slot fits inside the 1536 MiB dictionary, so both genimage.cfg
# layouts are pinned under it.
#
# Every row checks the exit status, stdout, stderr and the files left. A
# refusal must write exactly one stderr line, the prefix and a sentence.
#
# Needs the real xz and sha256sum: a missing one fails the suite, it never
# skips (TEST-REAL). Shells: each in TEST_SHELLS (default "sh dash"); a listed
# shell that is not installed fails the suite.
#
# Memory: each real compression reserves about 10.5 GiB of address space and
# touches about 2 GB, even on this 2 MiB fixture, because xz sizes its match
# finder by the dictionary. ubuntu-latest (16 GB) runs it as it is; a host
# with less memory refuses the reservation with "Cannot allocate memory".
#
# Run:  sh test/compress-image-test.sh
# The stub bodies below are single-quoted on purpose: the stub expands them.
# shellcheck disable=SC2016
set -u
LC_ALL=C
export LC_ALL

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/scripts/compress-image.sh"
[ -f "$SCRIPT" ] || { echo "FAILED: the file $SCRIPT is missing." >&2; exit 1; }
for t in xz sha256sum cmp; do
	command -v "$t" >/dev/null 2>&1 || { echo "FAILED: the $t command is not installed, and these tests need the real one." >&2; exit 1; }
done
REAL_XZ=$(command -v xz)
export REAL_XZ

TEST_SHELLS=${TEST_SHELLS:-sh dash}
for s in $TEST_SHELLS; do
	command -v "$s" >/dev/null 2>&1 || { echo "FAILED: the shell $s in TEST_SHELLS is not installed." >&2; exit 1; }
done

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 SH=""
ok() { pass=$((pass + 1)); printf '  ok [%s] %s\n' "$SH" "$1"; }
bad() {
	fail=$((fail + 1))
	printf '  FAIL [%s] %s: %s\n       rc=%s stdout=[%s] stderr=[%s]\n' \
		"$SH" "$1" "$2" "$RC" "$(cat "$TMP/out")" "$(cat "$TMP/err")" >&2
}

# The fixture: one 1 MiB random region written twice, 2,097,152 bytes. The
# repeat is 1 MiB away, the same shape as slot B a slot-size away from slot A.
head -c 1048576 /dev/urandom > "$TMP/region"
cat "$TMP/region" "$TMP/region" > "$TMP/fx.img"
rm -f "$TMP/region"
FX_SHA=$(sha256sum < "$TMP/fx.img")
FX_SHA=${FX_SHA%% *}

# run [ENV=VAL...] ARGS... — the script under $SH, from $TMP, with
# $TMP/bin first on PATH when a stub is installed. Status in RC, output in
# $TMP/out and $TMP/err.
run() {
	(cd "$TMP" && PATH="$TMP/bin:$PATH" "$SH" "$SCRIPT" "$@") > "$TMP/out" 2> "$TMP/err"
	RC=$?
}

# stub BODY — installs $TMP/bin/xz running BODY with the arguments in "$@";
# no stub at all means the real xz.
stub() {
	mkdir -p "$TMP/bin"
	{ printf '#!/bin/sh\n'; printf '%s\n' "$1"; } > "$TMP/bin/xz"
	chmod 0755 "$TMP/bin/xz"
}
unstub() { rm -rf "${TMP:?}/bin"; }

# clean — removes the output and its .tmp before a run.
clean() { rm -f "$TMP/fx.img.xz" "$TMP/fx.img.xz.tmp"; }

# no_files LABEL — neither the output nor its .tmp is left.
no_files() {
	if [ -e "$TMP/fx.img.xz" ] || [ -e "$TMP/fx.img.xz.tmp" ]; then bad "$1" "want no output and no .tmp left"
	else ok "$1: no output and no .tmp left"; fi
}

# refused LABEL STATUS WANT — exit STATUS, exactly one stderr line that is the
# prefix and a sentence (a capital, a full stop at the end), containing WANT.
refused() {
	_l=$1 _st=$2 _want=$3
	_line=$(cat "$TMP/err")
	if [ "$RC" != "$_st" ]; then bad "$_l" "want exit $_st"
	elif [ "$(wc -l < "$TMP/err" | tr -d ' ')" != 1 ]; then bad "$_l" "want exactly one stderr line"
	else
		case "$_line" in
			"compress-image: "[A-Z]*.)
				case "$_line" in
					*"$_want"*) ok "$_l: exit $_st and the sentence" ;;
					*) bad "$_l" "want stderr containing '$_want'" ;;
				esac ;;
			*) bad "$_l" "want the prefix and a sentence on stderr" ;;
		esac
	fi
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	unstub

	# TC-969-22: the happy path, with the real xz.
	clean
	run fx.img fx.img.xz
	if [ "$RC" = 0 ]; then ok "TC-969-22 exit 0"; else bad "TC-969-22" "want exit 0"; fi
	if [ -f "$TMP/fx.img.xz" ] && "$REAL_XZ" -dc "$TMP/fx.img.xz" | cmp -s - "$TMP/fx.img"; then
		ok "TC-969-22 round trip is byte-identical (cmp)"
	else bad "TC-969-22" "want xz -dc output identical to the fixture"; fi
	"$REAL_XZ" --robot -lvv "$TMP/fx.img.xz" > "$TMP/layout" 2>/dev/null
	streams=$(awk -F '\t' '$1 == "stream"' "$TMP/layout" | wc -l | tr -d ' ')
	blocks=$(awk -F '\t' '$1 == "block"' "$TMP/layout" | wc -l | tr -d ' ')
	bfilter=$(awk -F '\t' '$1 == "block" { print $NF }' "$TMP/layout")
	if [ "$streams" = 1 ] && [ "$blocks" = 1 ]; then ok "TC-969-22 one stream line and one block line"
	else bad "TC-969-22" "want one stream and one block line, got $streams and $blocks"; fi
	if [ "$bfilter" = "--lzma2=dict=1536MiB" ]; then ok "TC-969-22 block filter is --lzma2=dict=1536MiB"
	else bad "TC-969-22" "want block filter --lzma2=dict=1536MiB, got '$bfilter'"; fi
	size=$(wc -c < "$TMP/fx.img.xz" 2>/dev/null | tr -d ' ')
	if [ -n "$size" ] && [ "$size" -lt 1572864 ]; then ok "TC-969-22 output $size B is under 1,572,864 B (the repeat matched)"
	else bad "TC-969-22" "want output under 1572864 bytes, got '$size'"; fi
	want="Wrote fx.img.xz: $size bytes from 2097152, 1 block with the filter --lzma2=dict=1536MiB, round trip sha256 $FX_SHA."
	if [ "$(wc -l < "$TMP/out" | tr -d ' ')" = 1 ] && [ "$(cat "$TMP/out")" = "$want" ]; then ok "TC-969-22 stdout is the one summary line"
	else bad "TC-969-22" "want stdout exactly '$want'"; fi
	if [ -s "$TMP/err" ]; then bad "TC-969-22" "want empty stderr"; else ok "TC-969-22 stderr is empty"; fi
	if [ -e "$TMP/fx.img.xz.tmp" ]; then bad "TC-969-22" "want no .tmp left"; else ok "TC-969-22 no .tmp left"; fi

	# TC-969-23: usage errors and a missing input exit 2, with no output.
	usage="Needs two arguments: the image to compress and the .img.xz file to write."
	clean; run
	refused "TC-969-23 no arguments" 2 "$usage"
	clean; run fx.img
	refused "TC-969-23 one argument" 2 "$usage"
	no_files "TC-969-23 one argument"
	clean; run fx.img fx.img.xz extra
	refused "TC-969-23 three arguments" 2 "$usage"
	no_files "TC-969-23 three arguments"
	clean; run missing.img fx.img.xz
	refused "TC-969-23 missing input" 2 "The image missing.img does not exist, so it cannot be compressed."
	no_files "TC-969-23 missing input"
	# The rows above, together: stdout stays empty on every refusal.
	for args in "" "fx.img" "fx.img fx.img.xz extra" "missing.img fx.img.xz"; do
		# shellcheck disable=SC2086 # split on purpose: each string is an argument list
		run $args
		if [ -s "$TMP/out" ]; then bad "TC-969-23 '$args'" "want empty stdout"; else ok "TC-969-23 '$args': stdout empty"; fi
	done

	# TC-969-24 (a): xz fails while compressing, after writing a few bytes.
	stub 'case "$1" in -dc|--robot) exec "$REAL_XZ" "$@" ;; esac
printf partial
exit 3'
	clean; run fx.img fx.img.xz
	refused "TC-969-24 (a) xz exits 3" 1 "Compressing fx.img with xz failed with exit status 3."
	no_files "TC-969-24 (a)"
	unstub

	# TC-969-24 (b): --no-adjust: under a 1 GiB compression limit the real xz
	# refuses rather than shrinking the dictionary.
	clean
	(cd "$TMP" && XZ_DEFAULTS=--memlimit-compress=1GiB "$SH" "$SCRIPT" fx.img fx.img.xz) > "$TMP/out" 2> "$TMP/err"
	RC=$?
	refused "TC-969-24 (b) memory limit, --no-adjust" 1 "Compressing fx.img with xz failed with exit status 1."
	no_files "TC-969-24 (b) no smaller-dictionary output"

	# TC-969-25 (a): the decoder emits other bytes and exits 0.
	stub 'case "$1" in -dc) printf "not the image"; exit 0 ;; esac
exec "$REAL_XZ" "$@"'
	clean; run fx.img fx.img.xz
	wrong=$(printf 'not the image' | sha256sum); wrong=${wrong%% *}
	refused "TC-969-25 (a) wrong bytes" 1 "The compressed file fx.img.xz does not decompress to fx.img: the input's sha256 is $FX_SHA, and the decompressed sha256 is $wrong."
	no_files "TC-969-25 (a)"

	# TC-969-25 (b): the decoder emits the first half of the stream and exits 1.
	stub 'case "$1" in -dc) "$REAL_XZ" "$@" | head -c 1048576; exit 1 ;; esac
exec "$REAL_XZ" "$@"'
	clean; run fx.img fx.img.xz
	half=$(head -c 1048576 "$TMP/fx.img" | sha256sum); half=${half%% *}
	refused "TC-969-25 (b) half the stream" 1 "The compressed file fx.img.xz does not decompress to fx.img: the input's sha256 is $FX_SHA, and the decompressed sha256 is $half."
	no_files "TC-969-25 (b)"

	# TC-969-25 (c): the layout read reports a second block.
	stub 'case "$1" in --robot) "$REAL_XZ" "$@" | awk "{ print } /^block\t/ { print }"; exit 0 ;; esac
exec "$REAL_XZ" "$@"'
	clean; run fx.img fx.img.xz
	refused "TC-969-25 (c) two blocks" 1 "The compressed file fx.img.xz has 2 blocks and the filter --lzma2=dict=1536MiB, but slot B costs no download only with one block and --lzma2=dict=1536MiB."
	no_files "TC-969-25 (c)"

	# TC-969-25 (d): the layout read itself fails (F-969-31), which is its own
	# sentence, not the wrong-layout one.
	stub 'case "$1" in --robot) exit 2 ;; esac
exec "$REAL_XZ" "$@"'
	clean; run fx.img fx.img.xz
	refused "TC-969-25 (d) layout read fails" 1 "Reading the layout of fx.img.xz with xz --robot -lvv failed with exit status 2."
	if grep -qF "slot B costs no download" "$TMP/err"; then bad "TC-969-25 (d)" "want not the wrong-layout sentence"
	else ok "TC-969-25 (d) not the wrong-layout sentence"; fi
	no_files "TC-969-25 (d)"
	unstub
done

# TC-969-26: the slot fit. slot_fit FILE prints nothing and exits 0 when each of
# rootfs-0 and rootfs-1 in FILE has a size of at most 1535 MiB; otherwise one
# sentence per problem and exit 1. Sizes are genimage's: bytes, or a number
# with K, M or G (either case).
slot_fit() {
	awk -v file="$1" '
		function mib(s,   n, u) {
			n = s; sub(/[KkMmGg]$/, "", n); u = substr(s, length(s))
			if (u == "G" || u == "g") return n * 1024
			if (u == "M" || u == "m") return n
			if (u == "K" || u == "k") return n / 1024
			return n / 1048576
		}
		/^[ \t]*partition[ \t]+rootfs-[01][ \t]*\{/ { part = $2; next }
		part != "" && /^[ \t]*size[ \t]*=/ {
			v = $0; sub(/^[ \t]*size[ \t]*=[ \t]*/, "", v); sub(/[ \t#].*$/, "", v)
			seen[part] = v
			if (mib(v) > 1535)
				printf "The partition %s in %s is %s, above 1535 MiB: the slot distance must fit the 1.5 GiB maximum xz dictionary, or slot B is paid for again in the download.\n", part, file, v
			next
		}
		part != "" && /^[ \t]*\}/ { part = "" }
		END {
			if (!("rootfs-0" in seen)) printf "%s has no rootfs-0 partition with a size, so the slot fit cannot be checked.\n", file
			if (!("rootfs-1" in seen)) printf "%s has no rootfs-1 partition with a size, so the slot fit cannot be checked.\n", file
		}
	' "$1" > "$TMP/fit"
	[ ! -s "$TMP/fit" ]
}

SH=slot-fit RC=-
: > "$TMP/out"; : > "$TMP/err"
for sku in rpi n100; do
	cfg="$ROOT/board/rasputin/$sku/genimage.cfg"
	if slot_fit "$cfg"; then ok "TC-969-26 $sku rootfs-0 and rootfs-1 fit in 1535 MiB"
	else cp "$TMP/fit" "$TMP/err"; bad "TC-969-26 $sku" "want both slots at most 1535 MiB"; fi
done
# A scratch copy with rootfs-0 at 2G must fail with the named sentence.
scratch="$TMP/genimage-2G.cfg"
awk '/^[ \t]*partition[ \t]+rootfs-0/ { p = 1 } p && /^[ \t]*size[ \t]*=/ { sub(/=.*/, "= 2G"); p = 0 } { print }' \
	"$ROOT/board/rasputin/rpi/genimage.cfg" > "$scratch"
if slot_fit "$scratch"; then
	bad "TC-969-26 scratch 2G" "want the 2G copy to fail"
elif [ "$(cat "$TMP/fit")" = "The partition rootfs-0 in $scratch is 2G, above 1535 MiB: the slot distance must fit the 1.5 GiB maximum xz dictionary, or slot B is paid for again in the download." ]; then
	ok "TC-969-26 scratch 2G copy fails, naming the file, the partition and its size"
else cp "$TMP/fit" "$TMP/err"; bad "TC-969-26 scratch 2G" "want the one named sentence"; fi
rm -f "$scratch"
if [ -e "$scratch" ]; then bad "TC-969-26 scratch 2G" "want the scratch copy deleted"; else ok "TC-969-26 scratch copy deleted"; fi

echo "compress-image: $pass passed, $fail failed"
[ "$fail" = 0 ]
