#!/usr/bin/env bash
#
# source-bundle-test.sh — tests for the source-bundle half of a rasputin-os
# release (geekdojo/geekdojo-brain#970):
#
#   scripts/source-bundle.sh fetch   TC-970-13, against a fake curl first on
#                                    PATH that plays snapshot.debian.org
#   scripts/source-bundle.sh pack    TC-970-14 and TC-970-15, against fixture
#                                    legal-info, baked-sources, Buildroot and
#                                    repository trees
#   scripts/release-notes.sh         TC-970-16
#   scripts/manifest-sources.sh      TC-970-18
#   scripts/release-version.sh       its output against the inline logic the
#                                    build and sign jobs carried before it,
#                                    and its refusal
#
# Run:  bash test/source-bundle-test.sh
#
# Real git, tar, jq, sha1sum and sha256sum; no network, no GitHub.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$here/../scripts"
BUNDLE="$SCRIPTS/source-bundle.sh"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

failures=0
out=""
err=""
status=0
# run CMD... — runs it; leaves stdout in $out, stderr in $err, status in $status.
run() {
	status=0
	"$@" >"$tmp/out" 2>"$tmp/err" || status=$?
	out="$(cat "$tmp/out")"
	err="$(cat "$tmp/err")"
}
pass() { printf 'ok   %s\n' "$1"; }
flunk() {
	printf 'FAIL %s\n' "$1"
	[ -z "${2:-}" ] || printf '%s\n' "$2"
	failures=$((failures + 1))
}
want_status() { # NAME WANT
	if [ "$status" = "$2" ]; then pass "$1: exit $2"; else flunk "$1: exit $status, want $2" "stdout: $out
stderr: $err"; fi
}
has() { # NAME HAYSTACK NEEDLE
	if grep -qF -- "$3" <<<"$2"; then pass "$1"; else flunk "$1: lacks $3" "$2"; fi
}
lacks() { # NAME HAYSTACK NEEDLE
	if grep -qF -- "$3" <<<"$2"; then flunk "$1: contains $3" "$2"; else pass "$1"; fi
}
same() { # NAME GOT WANT
	if [ "$2" = "$3" ]; then pass "$1"; else flunk "$1" "got:
$2
want:
$3"; fi
}
sha1_of() { sha1sum <"$1" | awk '{print $1}'; }
sha256_of() { sha256sum <"$1" | awk '{print $1}'; }
size_of() { wc -c <"$1" | tr -d ' '; }

# --- fetch (TC-970-13) -----------------------------------------------------

# The fake curl: answers the srcfiles query from $FAKE_SNAP/srcfiles.json and
# /file/<sha1> from $FAKE_SNAP/by-sha/<sha1>, logs every URL, and fails like
# curl -f (status 22) on anything it has no answer for, or with $FAKE_CURL_EXIT.
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
set -eu
o="" url=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	-o) o="$2"; shift 2 ;;
	--retry | --max-time) shift 2 ;;
	-*) shift ;;
	*) url="$1"; shift ;;
	esac
done
printf '%s\n' "$url" >>"$FAKE_SNAP/log"
[ -z "${FAKE_CURL_EXIT:-}" ] || exit "$FAKE_CURL_EXIT"
case "$url" in
*/srcfiles\?fileinfo=1) src="$FAKE_SNAP/srcfiles.json" ;;
*/file/*) src="$FAKE_SNAP/by-sha/${url##*/}" ;;
*) exit 22 ;;
esac
[ -f "$src" ] || exit 22
cp "$src" "$o"
EOF
chmod +x "$fakebin/curl"

# snap NAME... — a fake snapshot serving the named files (content derived
# from the name) as the source package foo 1:1.2-3.
snap() {
	export FAKE_SNAP="$tmp/snap-$RANDOM$RANDOM"
	mkdir -p "$FAKE_SNAP/by-sha" "$FAKE_SNAP/files"
	: >"$FAKE_SNAP/log"
	local n s
	local result="[]" info="{}"
	for n in "$@"; do
		printf 'content of %s\n' "$n" >"$FAKE_SNAP/files/$n"
		s="$(sha1_of "$FAKE_SNAP/files/$n")"
		cp "$FAKE_SNAP/files/$n" "$FAKE_SNAP/by-sha/$s"
		result="$(jq -c --arg h "$s" '. + [{hash:$h}]' <<<"$result")"
		info="$(jq -c --arg h "$s" --arg n "$n" '. + {($h): [{archive_name:"debian", name:$n, path:"/pool/main/f/foo", size:1}]}' <<<"$info")"
	done
	jq -n --argjson r "$result" --argjson i "$info" \
		'{_comment:"foo", package:"foo", version:"1:1.2-3", result:$r, fileinfo:$i}' >"$FAKE_SNAP/srcfiles.json"
}

plan="$tmp/plan.tsv"
printf 'debian\tfoo\t1:1.2-3\n' >"$plan"
files=(foo_1.2-3.dsc foo_1.2.orig.tar.gz foo_1.2-3.debian.tar.xz)

# TC-970-13: good content is fetched, by sha1, under its Debian name.
snap "${files[@]}"
o="$tmp/fetch-good"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$o"
want_status "TC-970-13 good content" 0
for n in "${files[@]}"; do
	if cmp -s "$o/debian/foo_1.2-3/$n" "$FAKE_SNAP/files/$n"; then pass "TC-970-13 fetched $n"; else flunk "TC-970-13 $n not fetched intact" "$(ls -R "$o")"; fi
done
has "TC-970-13 the srcfiles query percent-encodes the version" "$(cat "$FAKE_SNAP/log")" "/mr/package/foo/1%3A1.2-3/srcfiles?fileinfo=1"
has "TC-970-13 the count line" "$out" "fetched 3 files for 1 Debian source packages"

# TC-970-13 (a): a file whose sha1 is not its address.
snap "${files[@]}"
bad="$(sha1_of "$FAKE_SNAP/files/foo_1.2.orig.tar.gz")"
printf 'tampered\n' >"$FAKE_SNAP/by-sha/$bad"
o="$tmp/fetch-badsha"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$o"
want_status "TC-970-13 (a) sha1 mismatch" 1
has "TC-970-13 (a) names the source and the address" "$err" "::error::source-bundle: foo_1.2.orig.tar.gz of the Debian source foo 1:1.2-3 has sha1"
has "TC-970-13 (a) gives the address" "$err" "addresses it as $bad"
if [ -e "$o/debian/foo_1.2-3/foo_1.2.orig.tar.gz" ]; then flunk "TC-970-13 (a) the tampered file was kept"; else pass "TC-970-13 (a) the tampered file is not kept"; fi
lacks "TC-970-13 (a) no count line" "$out" "fetched"

# TC-970-13 (b): snapshot lists nothing for foo 1:1.2-3.
snap
o="$tmp/fetch-empty"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$o"
want_status "TC-970-13 (b) no snapshot entry" 1
has "TC-970-13 (b) names the source" "$err" "snapshot.debian.org lists no files for the Debian source foo 1:1.2-3"
lacks "TC-970-13 (b) no count line" "$out" "fetched"

# TC-970-13 (b'): snapshot answers 404 (curl -f exits 22).
snap
rm "$FAKE_SNAP/srcfiles.json"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$tmp/fetch-404"
want_status "TC-970-13 (b') 404 from snapshot" 1
has "TC-970-13 (b') names the source" "$err" "did not answer for the Debian source foo 1:1.2-3"

# TC-970-13 (c): the network is down.
snap "${files[@]}"
run env PATH="$fakebin:$PATH" FAKE_CURL_EXIT=7 bash "$BUNDLE" fetch "$plan" "$tmp/fetch-down"
want_status "TC-970-13 (c) network down" 1
has "TC-970-13 (c) names the source" "$err" "did not answer for the Debian source foo 1:1.2-3"
lacks "TC-970-13 (c) no count line" "$out" "fetched"

# TC-970-13: a download that fails after a good srcfiles answer.
snap "${files[@]}"
rm "$FAKE_SNAP/by-sha/$(sha1_of "$FAKE_SNAP/files/foo_1.2-3.dsc")"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$tmp/fetch-dl"
want_status "TC-970-13 a failed file download" 1
has "TC-970-13 the failed download is named" "$err" "Downloading foo_1.2-3.dsc"

# TC-970-13: a non-JSON answer, a bad plan line, a missing plan, bad usage.
snap "${files[@]}"
printf '<html>maintenance</html>\n' >"$FAKE_SNAP/srcfiles.json"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$plan" "$tmp/fetch-html"
want_status "TC-970-13 non-JSON snapshot answer" 1
has "TC-970-13 non-JSON answer is named" "$err" "is not the JSON its API documents"
printf 'url\thttps://x\tv\n' >"$tmp/badplan"
run env PATH="$fakebin:$PATH" bash "$BUNDLE" fetch "$tmp/badplan" "$tmp/fetch-badplan"
want_status "TC-970-13 a plan line that is not debian" 1
run bash "$BUNDLE" fetch "$tmp/no-plan" "$tmp/fetch-noplan"
want_status "TC-970-13 a missing plan" 1
run bash "$BUNDLE" fetch "$plan"
want_status "TC-970-13 wrong argument count" 2
run bash "$BUNDLE" frobnicate
want_status "an unknown subcommand" 2

# --- pack (TC-970-14, TC-970-15) -------------------------------------------

br_tag=2026.08.1
api_ver=2026.11.2-dev.220
agent_ver=2026.11.2-dev.219
ver=2026.11.3-dev.5

# The repository being archived: init-buildroot.sh's pin and the two .mk pins.
repo="$tmp/repo"
mkdir -p "$repo/scripts" "$repo/package/rasputin-api" "$repo/package/rasputin-agent" "$repo/configs"
printf 'BR_TAG="%s"  # Buildroot %s\n' "$br_tag" "$br_tag" >"$repo/scripts/init-buildroot.sh"
printf 'RASPUTIN_API_VERSION = %s\n' "$api_ver" >"$repo/package/rasputin-api/rasputin-api.mk"
printf 'RASPUTIN_AGENT_VERSION = %s\n' "$agent_ver" >"$repo/package/rasputin-agent/rasputin-agent.mk"
printf 'BR2_x86_64=y\n' >"$repo/configs/rasputin_n100_defconfig"
git -C "$repo" init -q
git -C "$repo" -c user.name=t -c user.email=t@t add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm fixture
commit="$(git -C "$repo" rev-parse HEAD)"

# Buildroot, tagged at the pin.
br="$tmp/buildroot"
mkdir -p "$br"
printf 'Buildroot\n' >"$br/README"
git -C "$br" init -q
git -C "$br" -c user.name=t -c user.email=t@t add -A
git -C "$br" -c user.name=t -c user.email=t@t commit -qm br
git -C "$br" tag "$br_tag"

# legal-info as `make legal-info` writes it, host-sources/ included, with its
# checksum list made the way Buildroot's Makefile makes it.
legal="$tmp/legal-info"
mkdir -p "$legal/sources/busybox-1.37.0" "$legal/host-sources/host-cmake-3.31" "$legal/licenses/busybox-1.37.0" "$legal/host-licenses/cmake"
printf '"PACKAGE","VERSION","LICENSE","LICENSE FILES","SOURCE ARCHIVE","SOURCE SITE","DEPENDENCIES WITH LICENSES"\n"busybox","1.37.0","GPL-2.0","LICENSE","busybox-1.37.0.tar.bz2","https://busybox.net",""\n' >"$legal/manifest.csv"
printf 'busybox source\n' >"$legal/sources/busybox-1.37.0/busybox-1.37.0.tar.bz2"
printf 'GPL-2.0 text\n' >"$legal/licenses/busybox-1.37.0/LICENSE"
printf 'host cmake source\n' >"$legal/host-sources/host-cmake-3.31/cmake-3.31.tar.gz"
printf 'BSD\n' >"$legal/host-licenses/cmake/Copyright.txt"
printf 'BR2_x86_64=y\n' >"$legal/buildroot.config"
(cd "$legal" && find ./* -type f -exec sha256sum {} + | sed 's#  \./#  #' | LC_ALL=C sort -k2 >.legal-info.sha256 && mv .legal-info.sha256 legal-info.sha256)
grep -q 'host-sources/' "$legal/legal-info.sha256" || { echo "fixture: legal-info.sha256 should list host-sources"; exit 1; }

baked="$tmp/baked"
mkdir -p "$baked/debian/foo_1.2-3"
printf 'Format: 3.0 (quilt)\nSource: foo\n' >"$baked/debian/foo_1.2-3/foo_1.2-3.dsc"

pack() { # OUT [ENV...]
	local o="$1"
	shift
	run env SOURCE_BUNDLE_REPO="$repo" "$@" bash "$BUNDLE" pack n100 "$ver" "$legal" "$baked" "$br" "$o"
}

# TC-970-14: the contents, the shipped checksum list, and the meta.
o="$tmp/pack"
pack "$o"
want_status "TC-970-14 pack" 0
name="rasputin-os-n100-$ver-source"
tarf="$o/$name.tar"
if [ -f "$tarf" ]; then pass "TC-970-14 wrote $name.tar"; else flunk "TC-970-14 no $name.tar" "$(ls -la "$o")"; fi
listing="$(tar -tf "$tarf")"
for m in README legal-info/manifest.csv legal-info/legal-info.sha256 legal-info/buildroot.config \
	legal-info/sources/busybox-1.37.0/busybox-1.37.0.tar.bz2 legal-info/licenses/busybox-1.37.0/LICENSE \
	"rasputin-os-$commit.tar.gz" "buildroot-$br_tag.tar.gz" baked-images/debian/foo_1.2-3/foo_1.2-3.dsc; do
	has "TC-970-14 the bundle holds $m" "$listing" "$name/$m"
done
lacks "TC-970-14 no host-sources/ in the bundle" "$listing" "host-sources"
mkdir -p "$tmp/unpacked"
tar -C "$tmp/unpacked" -xf "$tarf"
u="$tmp/unpacked/$name"
readme="$(cat "$u/README")"
has "TC-970-14 README names the Buildroot tag" "$readme" "tag $br_tag, buildroot-$br_tag.tar.gz"
has "TC-970-14 README names the defconfig" "$readme" "configs/rasputin_n100_defconfig"
has "TC-970-14 README names the commit" "$readme" "rasputin-os commit $commit"
has "TC-970-14 README says why host sources are omitted" "$readme" "Host tools (host-sources/ in Buildroot's output) are omitted."
has "TC-970-14 README links the api source at its pin" "$readme" "rasputin-api    https://github.com/geekdojo/rasputin-control-plane/tree/v$api_ver"
has "TC-970-14 README links the agent source at its pin" "$readme" "rasputin-agent  https://github.com/geekdojo/rasputin-control-plane/tree/v$agent_ver"
lacks "TC-970-14 the shipped checksum list has no host-sources line" "$(cat "$u/legal-info/legal-info.sha256")" "host-sources/"
if check="$(cd "$u/legal-info" && sha256sum -c legal-info.sha256 2>&1)"; then
	pass "TC-970-14 sha256sum -c legal-info.sha256 passes in the unpacked bundle"
else
	flunk "TC-970-14 sha256sum -c fails in the unpacked bundle" "$check"
fi
lacks "TC-970-14 sha256sum -c reports nothing missing" "$check" "No such file"
same "TC-970-14 the repository archive is the built commit" \
	"$(tar -tzf "$u/rasputin-os-$commit.tar.gz" | LC_ALL=C sort | head -1)" "rasputin-os-$commit/"
has "TC-970-14 the Buildroot archive is the pinned tag" "$(tar -tzf "$u/buildroot-$br_tag.tar.gz")" "buildroot-$br_tag/README"
meta="$o/source-n100.json"
same "TC-970-14 the meta matches the tar" "$(jq -c . "$meta")" \
	"$(jq -nc --arg s "$(sha256_of "$tarf")" --argjson b "$(size_of "$tarf")" --arg n "$name.tar" \
		'{sku:"n100", source:$n, sourceSha256:$s, sourceSizeBytes:$b}')"

# TC-970-14: a legal-info that does not match its own checksum list is refused.
printf 'changed\n' >>"$legal/licenses/busybox-1.37.0/LICENSE"
pack "$tmp/pack-mismatch"
want_status "TC-970-14 legal-info off its checksum list" 1
has "TC-970-14 the mismatch is named" "$err" "does not match its own legal-info.sha256"
if [ -e "$tmp/pack-mismatch/source-n100.json" ]; then flunk "TC-970-14 a meta was written for a bad legal-info"; else pass "TC-970-14 no meta for a bad legal-info"; fi
printf 'GPL-2.0 text\n' >"$legal/licenses/busybox-1.37.0/LICENSE"

# TC-970-14: inputs pack cannot use.
run env SOURCE_BUNDLE_REPO="$repo" bash "$BUNDLE" pack n100 "$ver" "$tmp/no-legal" "$baked" "$br" "$tmp/p1"
want_status "TC-970-14 no legal-info" 1
has "TC-970-14 no legal-info is named" "$err" "has no manifest.csv"
run env SOURCE_BUNDLE_REPO="$repo" bash "$BUNDLE" pack n100 "$ver" "$legal" "$tmp/no-baked" "$br" "$tmp/p2"
want_status "TC-970-14 no baked sources" 1
git -C "$br" tag -d "$br_tag" >/dev/null
pack "$tmp/p3"
want_status "TC-970-14 Buildroot without the pinned tag" 1
has "TC-970-14 the missing tag is named" "$err" "Archiving Buildroot at tag $br_tag"
git -C "$br" tag "$br_tag"
run env SOURCE_BUNDLE_REPO="$repo" bash "$BUNDLE" pack N100 "$ver" "$legal" "$baked" "$br" "$tmp/p4"
want_status "TC-970-14 a SKU that is not a lower-case name" 1
run bash "$BUNDLE" pack n100 "$ver"
want_status "TC-970-14 wrong argument count" 2

# TC-970-15: the per-asset limit.
o="$tmp/pack-big"
pack "$o" SOURCE_BUNDLE_MAX_BYTES=1000
want_status "TC-970-15 over the limit" 1
has "TC-970-15 gives the bundle size" "$err" "$name.tar is $(size_of "$tarf") bytes"
has "TC-970-15 gives the limit" "$err" "over the 1000-byte limit"
if [ -e "$o/source-n100.json" ] || [ -e "$o/$name.tar" ]; then flunk "TC-970-15 a meta or tar was left behind" "$(ls -la "$o")"; else pass "TC-970-15 no meta and no tar"; fi

# --- release notes (TC-970-16) ---------------------------------------------

repo_url=https://github.com/geekdojo/rasputin-os
verify="Channel: \`dev\`. Verify the chain with the public root CA (https://rasputin.geekdojo.com/rasputin-root-ca.pem): \`manifest.json.sig\` is a detached DER CMS signature over \`manifest.json\`, which carries per-asset SHA-256. Verify commands: https://rasputin.geekdojo.com/docs/agents/."
run bash "$SCRIPTS/release-notes.sh" 2026.11.3-dev.5 dev "$repo_url" n100 rpi
want_status "TC-970-16 notes" 0
same "TC-970-16 the notes, exactly" "$out" "$verify

Source code: each image's GPL components ship with their complete corresponding source, one bundle per SKU, listed with its SHA-256 in \`manifest.json\`:

- n100: $repo_url/releases/download/2026.11.3-dev.5/rasputin-os-n100-2026.11.3-dev.5-source.tar
- rpi: $repo_url/releases/download/2026.11.3-dev.5/rasputin-os-rpi-2026.11.3-dev.5-source.tar"
run bash "$SCRIPTS/release-notes.sh" 2026.11.3-dev.5 dev "$repo_url" n100
same "TC-970-16 two links with both SKUs, one with n100 alone" "$(grep -c 'releases/download' <<<"$out")" 1
lacks "TC-970-16 no rpi link with n100 alone" "$out" "rpi"
run bash "$SCRIPTS/release-notes.sh" 2026.11.3-dev.5 dev "$repo_url"
want_status "TC-970-16 no SKU is a usage error" 2

# --- manifest merge (TC-970-18) --------------------------------------------

MERGE="$SCRIPTS/manifest-sources.sh"
art="$tmp/artifacts.jsonl"
jq -nc '{sku:"n100", raucb:"rasputin-os-n100-v.raucb"}' >"$art"
jq -nc '{sku:"rpi", raucb:"rasputin-os-rpi-v.raucb"}' >>"$art"
n100_sha="$(printf 'n' | sha256sum | awk '{print $1}')"
rpi_sha="$(printf 'r' | sha256sum | awk '{print $1}')"
metas() { # DIR — the two good metas, each in a file named for the OTHER sku,
	# so only selection by .sku can pair them correctly.
	mkdir -p "$1"
	jq -nc --arg s "$n100_sha" '{sku:"n100", source:"rasputin-os-n100-v-source.tar", sourceSha256:$s, sourceSizeBytes:111}' >"$1/source-rpi.json"
	jq -nc --arg s "$rpi_sha" '{sku:"rpi", source:"rasputin-os-rpi-v-source.tar", sourceSha256:$s, sourceSizeBytes:222}' >"$1/source-n100.json"
}

m="$tmp/meta-good"
metas "$m"
run bash "$MERGE" "$art" "$m"
want_status "TC-970-18 merge" 0
same "TC-970-18 the n100 entry carries only n100's bundle" "$(jq -c 'select(.sku=="n100") | [.source, .sourceSha256, .sourceSizeBytes]' <<<"$out")" \
	"[\"rasputin-os-n100-v-source.tar\",\"$n100_sha\",111]"
same "TC-970-18 the rpi entry carries only rpi's bundle" "$(jq -c 'select(.sku=="rpi") | [.source, .sourceSha256, .sourceSizeBytes]' <<<"$out")" \
	"[\"rasputin-os-rpi-v-source.tar\",\"$rpi_sha\",222]"
same "TC-970-18 the entries keep their own fields" "$(jq -r 'select(.sku=="rpi") | .raucb' <<<"$out")" "rasputin-os-rpi-v.raucb"

# merge_fails NAME WANT_STATUS TEXT — the last setup in $m must refuse.
merge_fails() {
	run bash "$MERGE" "$art" "$m"
	want_status "$1" "$2"
	has "$1: names the defect" "$err" "$3"
	same "$1: prints no entries" "$out" ""
}
m="$tmp/meta-missing"
metas "$m"
rm "$m/source-n100.json" # the rpi meta
merge_fails "TC-970-18 a missing rpi meta" 1 "No source meta has sku rpi"
m="$tmp/meta-dup"
metas "$m"
jq '.' "$m/source-rpi.json" >"$m/again.json"
merge_fails "TC-970-18 two metas for one sku" 1 "2 source meta files have sku n100"
m="$tmp/meta-swapped"
metas "$m"
jq '.source = "rasputin-os-rpi-v-source.tar"' "$m/source-rpi.json" >"$m/x" && mv "$m/x" "$m/source-rpi.json"
merge_fails "TC-970-18 a meta naming the other SKU's bundle" 1 "The n100 source meta names rasputin-os-rpi-v-source.tar"
m="$tmp/meta-badsha"
metas "$m"
jq '.sourceSha256 = "abc"' "$m/source-n100.json" >"$m/x" && mv "$m/x" "$m/source-n100.json"
merge_fails "TC-970-18 a bad sha256" 1 "The rpi source meta gives sourceSha256 abc"
m="$tmp/meta-badsize"
metas "$m"
jq '.sourceSizeBytes = 0' "$m/source-n100.json" >"$m/x" && mv "$m/x" "$m/source-n100.json"
merge_fails "TC-970-18 a zero size" 1 "The rpi source meta gives sourceSizeBytes 0"
m="$tmp/meta-nosku"
metas "$m"
printf '%s\n' '{"raucb":"x"}' >"$tmp/art-nosku.jsonl"
run bash "$MERGE" "$tmp/art-nosku.jsonl" "$m"
want_status "TC-970-18 an entry with no sku" 1
m="$tmp/meta-notjson"
metas "$m"
printf 'nope {\n' >"$m/source-n100.json"
merge_fails "TC-970-18 a non-JSON meta" 2 "is not valid JSON"
m="$tmp/meta-empty"
mkdir -p "$m"
merge_fails "TC-970-18 no metas at all" 1 "No source meta has sku n100"
run bash "$MERGE" "$art" "$tmp/no-such-dir"
want_status "TC-970-18 no meta directory" 2
run bash "$MERGE" "$art"
want_status "TC-970-18 wrong argument count" 2
printf 'nope {\n' >"$tmp/art-bad.jsonl"
m="$tmp/meta-good"
run bash "$MERGE" "$tmp/art-bad.jsonl" "$m"
want_status "TC-970-18 a non-JSON artifact list" 2

# --- release-version.sh ----------------------------------------------------

# The two inline copies release.yml's build and sign jobs carried before
# scripts/release-version.sh, verbatim but for writing to stdout instead of
# $GITHUB_OUTPUT. The script must print what each printed.
inline_build() {
	if [ "${GITHUB_REF_TYPE}" = "tag" ]; then
		echo "version=${GITHUB_REF_NAME}"
		case "${GITHUB_REF_NAME}" in
		*-dev*) echo "channel=dev" ;;
		*) echo "channel=stable" ;;
		esac
	else
		if [ -z "${TARGET_VERSION}" ]; then
			return 1
		fi
		echo "version=${TARGET_VERSION}-dev.${GITHUB_RUN_NUMBER}"
		echo "channel=dev"
	fi
}
inline_sign() {
	if [ "${GITHUB_REF_TYPE}" = "tag" ]; then
		VERSION="${GITHUB_REF_NAME}"
	else
		if [ -z "${TARGET_VERSION}" ]; then
			return 1
		fi
		VERSION="${TARGET_VERSION}-dev.${GITHUB_RUN_NUMBER}"
	fi
	case "$VERSION" in
	*-dev*) CHANNEL=dev PRERELEASE=true ;;
	*) CHANNEL=stable PRERELEASE=false ;;
	esac
	echo "version=$VERSION"
	echo "channel=$CHANNEL"
	echo "prerelease=$PRERELEASE"
}
# version_case NAME REF_TYPE REF_NAME TARGET_VERSION RUN_NUMBER WANT
version_case() {
	local name="$1" want="$6"
	export GITHUB_REF_TYPE="$2" GITHUB_REF_NAME="$3" TARGET_VERSION="$4" GITHUB_RUN_NUMBER="$5"
	run bash "$SCRIPTS/release-version.sh"
	want_status "release-version gives the same version, channel and prerelease for $name" 0
	same "release-version for $name" "$out" "$want"
	same "release-version for $name matches the build job's inline copy" "$(head -2 <<<"$out")" "$(inline_build)"
	same "release-version for $name matches the sign job's inline copy" "$out" "$(inline_sign)"
}
version_case "a stable tag" tag 2026.11.3 "2026.12.1" 77 $'version=2026.11.3\nchannel=stable\nprerelease=false'
version_case "a -dev tag" tag 2026.11.3-dev.4 "" 77 $'version=2026.11.3-dev.4\nchannel=dev\nprerelease=true'
version_case "a dispatch" branch main 2026.11.3 412 $'version=2026.11.3-dev.412\nchannel=dev\nprerelease=true'

export GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main GITHUB_RUN_NUMBER=412
for tv in unset empty; do
	if [ "$tv" = unset ]; then unset TARGET_VERSION; else export TARGET_VERSION=""; fi
	run bash "$SCRIPTS/release-version.sh"
	want_status "release-version refuses a dispatch with TARGET_VERSION $tv" 1
	has "release-version names the org var when TARGET_VERSION is $tv" "$err" "::error::release-version: The org var RASPUTIN_VERSION is unset"
	same "release-version prints no version when TARGET_VERSION is $tv" "$out" ""
done

if [ "$failures" -ne 0 ]; then
	echo "$failures source-bundle test(s) failed"
	exit 1
fi
echo "all source-bundle tests passed"
