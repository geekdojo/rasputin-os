#!/bin/sh
#
# compress-image.sh IN.img OUT.img.xz
#
# Compresses a flashable Rasputin OS image into the .img.xz a release
# publishes (geekdojo/geekdojo-brain#969).
#
# Why one xz stream. Each image carries the same rootfs twice: slot A, and
# slot B filled with a copy at flash so a box has a fallback before its first
# OTA. Multi-threaded xz cuts the image into independent blocks, so slot B is
# compressed from scratch and paid for again in the download. One block with a
# dictionary larger than the slot distance (1 GiB plus a sector on rpi) lets
# xz match slot B against slot A, which roughly halves the asset. The .xz
# header can only store 2^n or 2^n + 2^(n-1) bytes, so the next dictionary
# above 1 GiB is 1536 MiB. test/compress-image-test.sh pins the slot sizes in
# both genimage.cfg files under that.
#
# What it does, in order, and it writes OUT only after all of it passes:
#   1. compresses IN into OUT.tmp with one thread and the filter below;
#      --no-adjust makes xz fail instead of quietly shrinking the dictionary
#      to fit a memory limit, which would bring slot B's cost back;
#   2. checks the round trip: OUT.tmp must decompress to IN's sha256;
#   3. reads the layout back from `xz --robot -lvv`: exactly one block, whose
#      filter chain is --lzma2=dict=1536MiB;
#   4. moves OUT.tmp to OUT and prints one line with the values it read.
# An EXIT trap removes OUT.tmp on every failure, so nothing half-made is left
# for the release job to upload.
#
# The cost, accepted by Bryce on 2026-11-14: decoding needs about 1.6 GiB of
# memory, so Rufus (a 64 MiB dictionary cap) cannot open the image and
# balenaEtcher needs about 8 GB of RAM. The xz command line and Raspberry Pi
# Imager set no such limit. Compressing needs about 11 GB, which is why
# release.yml runs this in its own job on ubuntu-latest.
#
# Output: the summary line on stdout. Each refusal is one sentence on stderr.
# xz's own diagnostics, when it has any, go to stdout, so stderr carries only
# that sentence.
#
# Exit status:
#   0  OUT written and checked
#   1  xz failed, the round trip did not match, or the layout is wrong or
#      could not be read
#   2  usage error, IN missing, or a needed command is not installed
#
# test/compress-image-test.sh covers every status.
set -u
LC_ALL=C
export LC_ALL

# The dictionary, defined once: the compression filter and the filter chain
# the layout check expects are both built from it.
DICT=1536MiB
FILTER="--lzma2=preset=6,dict=$DICT,mf=hc4"
WANT_FILTER="--lzma2=dict=$DICT"

fail() {
	_status=$1
	shift
	printf 'compress-image: %s\n' "$*" >&2
	exit "$_status"
}

[ "$#" -eq 2 ] || fail 2 "Needs two arguments: the image to compress and the .img.xz file to write."
in=$1
out=$2
[ -f "$in" ] || fail 2 "The image $in does not exist, so it cannot be compressed."
for tool in xz sha256sum; do
	command -v "$tool" >/dev/null 2>&1 ||
		fail 2 "The $tool command is not installed, and it is needed to compress the image."
done

tmp="$out.tmp"
trap 'rm -f -- "$tmp"' EXIT
trap 'exit 1' HUP INT TERM

# fd 3 is the caller's stdout: xz's own messages go there, so stderr holds
# only this script's sentence.
exec 3>&1

# 1. Compress.
xz --threads=1 --no-adjust --stdout "$FILTER" -- "$in" 2>&3 > "$tmp" || {
	rc=$?
	fail 1 "Compressing $in with xz failed with exit status $rc."
}

# 2. Round trip. A decoder that fails part way, or emits other bytes, gives a
# different sha256, so this compare is the check.
in_sha=$(sha256sum < "$in")
in_sha=${in_sha%% *}
got_sha=$( { xz -dc -- "$tmp" 2>&3; } | sha256sum)
got_sha=${got_sha%% *}
if [ -z "$in_sha" ] || [ "$in_sha" != "$got_sha" ]; then
	fail 1 "The compressed file $out does not decompress to $in: the input's sha256 is $in_sha, and the decompressed sha256 is $got_sha."
fi

# 3. Layout, read from the file. In --robot -lvv output a block line is
# tab-separated and its last field is the filter chain.
layout=$(xz --robot -lvv -- "$tmp" 2>&3) || {
	rc=$?
	fail 1 "Reading the layout of $out with xz --robot -lvv failed with exit status $rc."
}
blocks=$(printf '%s\n' "$layout" | awk -F '\t' '$1 == "block" { n++ } END { print n + 0 }')
filter=$(printf '%s\n' "$layout" | awk -F '\t' '$1 == "block" { print $NF; exit }')
[ -n "$filter" ] || filter=none
if [ "$blocks" != 1 ] || [ "$filter" != "$WANT_FILTER" ]; then
	fail 1 "The compressed file $out has $blocks blocks and the filter $filter, but slot B costs no download only with one block and $WANT_FILTER."
fi

# 4. Publish the file under its name.
mv -f -- "$tmp" "$out" || fail 1 "Moving $tmp to $out failed, so $out was not written."
out_size=$(wc -c < "$out" | tr -d ' ')
in_size=$(wc -c < "$in" | tr -d ' ')
printf 'Wrote %s: %s bytes from %s, %s block with the filter %s, round trip sha256 %s.\n' \
	"$out" "$out_size" "$in_size" "$blocks" "$filter" "$in_sha"
