#!/usr/bin/env bash
#
# release-manifest-gate-test.sh — tests for scripts/release-manifest-gate.sh.
#
# Run:  bash test/release-manifest-gate-test.sh
#
# Builds a throwaway release-out/ with two SKUs (a .raucb and an .img.xz each),
# a manifest.json in the schema release.yml's sign step writes, and a stand-in
# manifest.json.sig, then checks every exit status of the gate against copies of
# it: intact, truncated, altered, missing, extra, pin mismatches, malformed
# manifests and bad arguments. Real jq and sha256sum; no network, no GitHub.
# (geekdojo/geekdojo-brain#902)

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
GATE="${GATE:-$here/../scripts/release-manifest-gate.sh}"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

ver=2026.10.5-dev.1
sha_of() { sha256sum <"$1" | awk '{print $1}'; }
size_of() { wc -c <"$1" | tr -d ' '; }

# The fixture. Each file's content differs, so no two share a hash.
fix="$tmp/fixture"
mkdir -p "$fix"
: >"$tmp/artifacts.jsonl"
for sku in n100 rpi; do
	raucb="rasputin-os-$sku-$ver.raucb"
	image="rasputin-os-$sku-$ver.img.xz"
	for i in $(seq 1 200); do printf 'bundle %s line %d\n' "$sku" "$i"; done >"$fix/$raucb"
	for i in $(seq 1 400); do printf 'image %s line %d\n' "$sku" "$i"; done >"$fix/$image"
	jq -nc --arg sku "$sku" \
		--arg raucb "$raucb" --arg raucb_sha "$(sha_of "$fix/$raucb")" --argjson raucb_sz "$(size_of "$fix/$raucb")" \
		--arg image "$image" --arg imgxz_sha "$(sha_of "$fix/$image")" --argjson imgxz_sz "$(size_of "$fix/$image")" \
		'{sku:$sku, architecture:"x", compatible:"x",
		  raucb:$raucb, sha256:$raucb_sha, sizeBytes:$raucb_sz,
		  image:$image, imageSha256:$imgxz_sha, imageSizeBytes:$imgxz_sz,
		  signedBy:"test", buildDate:"2026-10-31T00:00:00Z"}' >>"$tmp/artifacts.jsonl"
done
jq -n --arg version "$ver" --slurpfile artifacts "$tmp/artifacts.jsonl" \
	'{version:$version, channel:"dev", artifacts:$artifacts}' >"$fix/manifest.json"
printf 'stand-in detached signature over manifest.json\n' >"$fix/manifest.json.sig"
pin="$(sha_of "$fix/manifest.json")"
sigpin="$(sha_of "$fix/manifest.json.sig")"

n100_raucb="rasputin-os-n100-$ver.raucb"
n100_img="rasputin-os-n100-$ver.img.xz"
rpi_raucb="rasputin-os-rpi-$ver.raucb"
rpi_img="rasputin-os-rpi-$ver.img.xz"

# fresh NAME — a new copy of the fixture at $tmp/NAME; prints its path.
fresh() {
	rm -rf -- "${tmp:?}/$1"
	cp -R "$fix" "$tmp/$1"
	printf '%s\n' "$tmp/$1"
}

# set_manifest DIR JQ_FILTER — rewrite DIR/manifest.json; prints the new pin.
set_manifest() {
	jq "$2" "$1/manifest.json" >"$1/manifest.json.new"
	mv "$1/manifest.json.new" "$1/manifest.json"
	sha_of "$1/manifest.json"
}

failures=0
out=""
# check NAME WANT_STATUS ARGS... — runs the gate; leaves the combined output in
# $out for content assertions.
check() {
	local name="$1" want_status="$2"
	shift 2
	local status=0
	out="$("$GATE" "$@" 2>&1)" || status=$?
	if [ "$status" != "$want_status" ]; then
		printf 'FAIL %s: exit %s, want %s\n%s\n' "$name" "$status" "$want_status" "$out"
		failures=$((failures + 1))
		return 1
	fi
	printf 'ok   %s\n' "$name"
}
# has NAME TEXT — the last check's output contains TEXT (a fixed string).
has() {
	if grep -qF -- "$2" <<<"$out"; then
		printf 'ok   %s\n' "$1"
	else
		printf 'FAIL %s: output lacks %q\n%s\n' "$1" "$2" "$out"
		failures=$((failures + 1))
	fi
}
# lacks NAME TEXT — the last check's output does not contain TEXT.
lacks() {
	if grep -qF -- "$2" <<<"$out"; then
		printf 'FAIL %s: output contains %q\n%s\n' "$1" "$2" "$out"
		failures=$((failures + 1))
	else
		printf 'ok   %s\n' "$1"
	fi
}

# TC-902-01: an intact release passes, with one ok line per file in DIR/* and a
# summary line; the checked set is exactly the directory listing.
d="$(fresh intact)"
check "intact release passes" 0 "$d" "$pin" "$sigpin" || true
ok_names="$(awk '$1 == "ok" {print $2}' <<<"$out" | sort)"
ls_names="$(for f in "$d"/*; do basename -- "$f"; done | sort)"
if [ "$ok_names" = "$ls_names" ] && [ "$(wc -l <<<"$ok_names" | tr -d ' ')" = 6 ]; then
	printf 'ok   %s\n' "intact release: the ok names are exactly the 6 files in the directory"
else
	printf 'FAIL %s\nok names:\n%s\nls:\n%s\n' "intact release: ok names differ from the directory" "$ok_names" "$ls_names"
	failures=$((failures + 1))
fi
has "intact release: ok line carries bytes and sha256" "ok $rpi_img $(size_of "$d/$rpi_img") $(sha_of "$d/$rpi_img")"
has "intact release: summary line" "all 6 files in $d match the signed manifest"

# TC-902-02: an image truncated under the same name (the dev.351 shape).
d="$(fresh truncated)"
want_bytes="$(size_of "$d/$rpi_img")"
head -c 1000 "$fix/$rpi_img" >"$d/$rpi_img"
check "truncated image fails" 1 "$d" "$pin" "$sigpin" || true
has "truncated image: one error naming the file and both sizes" \
	"::error::release-manifest-gate: $rpi_img is 1000 bytes, but the signed manifest gives $want_bytes."

# TC-902-03: same size, one byte changed.
d="$(fresh altered)"
want_sha="$(sha_of "$d/$n100_raucb")"
{ printf 'X'; tail -c +2 "$fix/$n100_raucb"; } >"$d/$n100_raucb"
got_sha="$(sha_of "$d/$n100_raucb")"
check "altered bundle (same size) fails" 1 "$d" "$pin" "$sigpin" || true
has "altered bundle: names the file and both sha256 values" \
	"$n100_raucb has sha256 $got_sha, but the signed manifest gives $want_sha."

# TC-902-04: a manifest entry with no file, for each kind of entry.
d="$(fresh missing-raucb)"
rm "$d/$rpi_raucb"
check "missing .raucb fails" 1 "$d" "$pin" "$sigpin" || true
has "missing .raucb is named" "$rpi_raucb is in the signed manifest but missing"
d="$(fresh missing-img)"
rm "$d/$n100_img"
check "missing .img.xz fails" 1 "$d" "$pin" "$sigpin" || true
has "missing .img.xz is named" "$n100_img is in the signed manifest but missing"

# TC-902-05: an extra file that would be published but is not in the manifest.
d="$(fresh extra)"
printf 'stray\n' >"$d/stray.bin"
check "extra file fails" 1 "$d" "$pin" "$sigpin" || true
has "extra file is named" "stray.bin would be published but is not in the signed manifest"

# TC-902-06: the manifest.json and .sig pins.
d="$(fresh sig-missing)"
rm "$d/manifest.json.sig"
check "missing manifest.json.sig fails" 1 "$d" "$pin" "$sigpin" || true
has "missing manifest.json.sig is named" "manifest.json.sig is missing"
d="$(fresh sig-differs)"
printf 'another signature\n' >"$d/manifest.json.sig"
check "manifest.json.sig not matching its pin fails" 1 "$d" "$pin" "$sigpin" || true
has "manifest.json.sig pin failure is named" "manifest.json.sig has sha256 $(sha_of "$d/manifest.json.sig"), but the sign job pinned $sigpin."
d="$(fresh manifest-edited)"
set_manifest "$d" '.version = "2099.01.1"' >/dev/null
check "edited manifest.json (entry hashes still match) fails" 1 "$d" "$pin" "$sigpin" || true
has "edited manifest.json pin failure is named" "manifest.json has sha256 $(sha_of "$d/manifest.json"), but the sign job pinned $pin."
lacks "edited manifest.json: no artifact is reported" "signed manifest gives"

# TC-902-07: every defect reported in one run.
d="$(fresh two-bad)"
head -c 1000 "$fix/$rpi_img" >"$d/$rpi_img"
{ printf 'X'; tail -c +2 "$fix/$n100_raucb"; } >"$d/$n100_raucb"
check "two bad files fail" 1 "$d" "$pin" "$sigpin" || true
has "two bad files: the truncated image is named" "::error::release-manifest-gate: $rpi_img is 1000 bytes"
has "two bad files: the altered bundle is named" "::error::release-manifest-gate: $n100_raucb has sha256"
has "two bad files: the defect count is 2" "2 defect(s)"

# TC-902-08: malformed manifests refuse (status 2) with no ok summary. Each is
# re-pinned, so only the malformation is under test.
malformed() {
	local name="$1" filter="$2" d p
	d="$(fresh "malformed-$name")"
	p="$(set_manifest "$d" "$filter")"
	check "malformed manifest refuses: $name" 2 "$d" "$p" "$sigpin" || true
	lacks "malformed manifest prints no summary: $name" "match the signed manifest"
}
d="$(fresh malformed-nonjson)"
printf 'not json {\n' >"$d/manifest.json"
check "malformed manifest refuses: not JSON" 2 "$d" "$(sha_of "$d/manifest.json")" "$sigpin" || true
lacks "malformed manifest prints no summary: not JSON" "match the signed manifest"
malformed "null imageSha256" '.artifacts[0].imageSha256 = null'
malformed "empty artifacts" '.artifacts = []'
malformed "name containing a slash" '.artifacts[1].raucb = "../" + .artifacts[1].raucb'
malformed "duplicate raucb name" '.artifacts[1].raucb = .artifacts[0].raucb'

# TC-902-09: argument and pin refusals, including an empty pin (a wiring
# regression that loses the sign job's output).
d="$(fresh args)"
check "two arguments refuse" 2 "$d" "$pin" || true
check "four arguments refuse" 2 "$d" "$pin" "$sigpin" extra || true
check "an empty manifest pin refuses" 2 "$d" "" "$sigpin" || true
check "a 63-character pin refuses" 2 "$d" "${pin:0:63}" "$sigpin" || true
check "a non-hex pin refuses" 2 "$d" "$pin" "$(printf 'g%.0s' $(seq 1 64))" || true
check "a missing directory refuses" 2 "$tmp/no-such-dir" "$pin" "$sigpin" || true

if [ "$failures" -ne 0 ]; then
	echo "$failures release-manifest-gate test(s) failed"
	exit 1
fi
echo "all release-manifest-gate tests passed"
