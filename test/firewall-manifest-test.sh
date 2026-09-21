#!/bin/sh
# Tests for the baked firewall image descriptor: the pin file, and what
# post-build.sh does with it.
#
# Why this is tested at all.
#
# The descriptor is two small files in the rootfs that NOTHING on a healthy
# network ever reads — the control plane prefers a live GitHub lookup and only
# falls back to the baked pair when it has no route out. So an image that
# quietly stopped baking them boots, passes every smoke test and looks
# identical, and fails exactly once: in front of an operator doing a greenfield
# bring-up on a controlplane with the no-DHCP fallback address and no default
# gateway, who now cannot flash the firewall that would give it internet. That
# invisible hole is the whole reason for geekdojo/geekdojo-brain#595, so the
# cases below are mostly REFUSALS — every way the bake can go wrong has to stop
# the build rather than ship a hollow image.
#
# The pin itself is pinned too. "Fetch the latest firewall release at build
# time" is the shape that burned 2026.09.2 (geekdojo/geekdojo-brain#208), and a
# pin file that grew a second line, a leading "v" or a comment-only body would
# otherwise be found by a 404 in a 25-minute release build.
#
# Everything is faked: a throwaway PKI, a fake release tree served by a stub
# `curl` on PATH, and a scratch copy of post-build.sh beside a scratch pin file
# so pin variants are testable without touching the repo's. No network, no
# root, no Buildroot. Real openssl does the signing and the verifying, because
# the signature check is the half that must not be simulated.
#
# Run:  sh test/firewall-manifest-test.sh
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
REAL_PIN="$ROOT/board/rasputin/common/firewall-pin.txt"
CI="$ROOT/.github/workflows/ci.yml"
for f in "$POSTBUILD" "$REAL_PIN" "$CI"; do
	[ -f "$f" ] || { echo "missing: $f"; exit 1; }
done
command -v openssl >/dev/null 2>&1 || { echo "openssl is required"; exit 1; }

fails=0
check() {
	if [ "$2" = "$3" ]; then echo "ok   — $1"
	else echo "FAIL — $1: expected '$3', got '$2'"; fails=$((fails + 1)); fi
}
DEST=usr/share/rasputin/firewall            # the contract path, relative to /
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
W="$TMP/pki"; BIN="$TMP/bin"; mkdir -p "$W" "$BIN"

# --- a throwaway PKI --------------------------------------------------------
# The production signing leaf's profile (leaf-003: digitalSignature, codeSigning
# + emailProtection + the release OID), so the default purpose openssl applies
# on verify is the one the real chain satisfies.
printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\n[dn]\n[v3]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n' > "$W/ca.cnf"
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning,emailProtection,1.3.6.1.4.1.66587.1.1.1\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$W/leaf.ext"

mkca() { # mkca <name>
	openssl ecparam -name prime256v1 -genkey -noout -out "$W/$1.key" 2>/dev/null
	openssl req -new -x509 -key "$W/$1.key" -subj "/CN=Test $1" -days 2 \
		-config "$W/ca.cnf" -extensions v3 -out "$W/$1.pem" 2>/dev/null
}
mkleaf() { # mkleaf <name> <issuer>
	openssl ecparam -name prime256v1 -genkey -noout -out "$W/$1.key" 2>/dev/null
	openssl req -new -key "$W/$1.key" -subj "/CN=Test $1" -config "$W/ca.cnf" \
		-out "$W/$1.csr" 2>/dev/null
	openssl x509 -req -in "$W/$1.csr" -CA "$W/$2.pem" -CAkey "$W/$2.key" \
		-CAcreateserial -days 2 -extfile "$W/leaf.ext" -out "$W/$1.pem" 2>/dev/null
}
mkca root;  mkleaf leaf root
mkca other; mkleaf leaf-other other

# --- a fake release tree + the stub curl that serves it ---------------------
# publish <tree> <tag> <version-in-manifest> <signing-leaf>
publish() {
	mkdir -p "$1/$2"
	printf '{\n  "version": "%s",\n  "channel": "dev",\n  "artifacts": [{"sku":"fw-n100","image":"rasputin-fw-n100-%s-ab.img.gz","sha256":"%s"}]\n}\n' \
		"$3" "$3" "0000000000000000000000000000000000000000000000000000000000000000" \
		> "$1/$2/manifest.json"
	# Same recipe as release.yml's sign step and the firewall repo's sign_file():
	# a detached DER CMS signature over the manifest bytes.
	openssl cms -sign -binary -in "$1/$2/manifest.json" \
		-signer "$W/$4.pem" -inkey "$W/$4.key" \
		-outform DER -out "$1/$2/manifest.json.sig" 2>/dev/null
}

cat > "$BIN/curl" <<'STUB'
#!/bin/sh
# Stub curl: serves $FAKE_RELEASES/<tag>/<asset> for the release-download URL
# shape post-build.sh builds, and 404s (exit 22, as `curl -f` does) for
# anything the fake tree does not hold. Never touches the network.
out=""; url=""
while [ $# -gt 0 ]; do
	case "$1" in
		-o) out="$2"; shift 2 ;;
		--retry) shift 2 ;;
		-*) shift ;;
		*) url="$1"; shift ;;
	esac
done
asset="${url##*/}"
rest="${url%/*}"; tag="${rest##*/}"
src="$FAKE_RELEASES/$tag/$asset"
[ -f "$src" ] || exit 22
cat "$src" > "$out"
STUB
chmod +x "$BIN/curl"

# --- the scratch board tree -------------------------------------------------
# A copy of the REAL post-build.sh beside a per-case pin file, so a case can
# vary the pin (or remove it) without editing anything in the repo. The script
# resolves the pin from its own directory, which is what makes this work.
prep() { # prep <case> <pin text | NOPIN> [NOCA]
	C="$TMP/$1"; rm -rf "$C"
	mkdir -p "$C/board/rasputin/common" "$C/target/etc/rasputin/trust"
	cp "$POSTBUILD" "$C/board/rasputin/common/post-build.sh"
	[ "$2" = NOPIN ] || printf '%s' "$2" > "$C/board/rasputin/common/firewall-pin.txt"
	[ "${3:-}" = NOCA ] || cp "$W/root.pem" "$C/target/etc/rasputin/trust/root-ca.pem"
	TGT="$C/target"
}
run() { # run <soc> <release tree>; sets $rc, prints combined output
	PATH="$BIN:$PATH" FAKE_RELEASES="$2" \
		sh "$C/board/rasputin/common/post-build.sh" "$TGT" "$1" 2>&1
}
baked() { [ -f "$TGT/$DEST/manifest.json" ] && echo yes || echo no; }

echo "1. the pin file in the repo"

# The same read post-build.sh does, so "it parses" means it parses THERE.
PIN_VERSION=$(awk '
	/^[ \t]*#/ { next }
	/^[ \t]*$/ { next }
	{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); print; n++ }
	END { exit (n == 1 ? 0 : 1) }' "$REAL_PIN")
check "the pin holds exactly one non-comment, non-blank line" "$?" "0"
check "it is a bare CalVer version (no leading 'v')" \
	"$(printf '%s\n' "$PIN_VERSION" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]+(-dev\.[0-9]+)?$' && echo yes || echo no)" "yes"
# The pin is a compatibility statement someone has to bump on purpose; a file
# that does not say so invites a drive-by refresh, which is the "latest" shape
# in slow motion.
check "it says the bump is deliberate" \
	"$(grep -qi 'deliberate' "$REAL_PIN" && echo yes || echo no)" "yes"
check "it cites the issue" \
	"$(grep -q 'geekdojo-brain#595' "$REAL_PIN" && echo yes || echo no)" "yes"

GOOD="$TMP/releases"; publish "$GOOD" "$PIN_VERSION" "$PIN_VERSION" leaf

echo
echo "2. the happy path"

prep ok "$PIN_VERSION"; out=$(run n100 "$GOOD"); rc=$?
check "exits 0" "$rc" "0"
check "manifest.json lands at /$DEST" "$(baked)" "yes"
check "manifest.json.sig lands beside it" \
	"$([ -f "$TGT/$DEST/manifest.json.sig" ] && echo yes || echo no)" "yes"
check "  the manifest is the published bytes, unmodified" \
	"$(cmp -s "$GOOD/$PIN_VERSION/manifest.json" "$TGT/$DEST/manifest.json" && echo same || echo differs)" "same"
check "  the signature is the published bytes, unmodified" \
	"$(cmp -s "$GOOD/$PIN_VERSION/manifest.json.sig" "$TGT/$DEST/manifest.json.sig" && echo same || echo differs)" "same"
check "  manifest.json is 0644" "$(mode_of "$TGT/$DEST/manifest.json")" "644"
check "  manifest.json.sig is 0644" "$(mode_of "$TGT/$DEST/manifest.json.sig")" "644"
case "$out" in *"$PIN_VERSION"*) echo "ok   — the build says which firewall release it baked" ;;
	*) echo "FAIL — the build says which firewall release it baked: got '$out'"; fails=$((fails + 1)) ;; esac
check "nothing is left behind in the rootfs but the two files" \
	"$(ls "$TGT/$DEST" | tr '\n' ' ')" "manifest.json manifest.json.sig "

# Both SKUs get it. The rpi run then dies in the second-kernel step (there is no
# Buildroot tree here), which is fine and deliberate: it proves the bake happens
# BEFORE that SoC-specific block, i.e. on one code path for both images.
prep rpi "$PIN_VERSION"; run rpi "$GOOD" >/dev/null 2>&1
check "baked on rpi too (one code path, both SKUs)" "$(baked)" "yes"

echo
echo "3. every way it must refuse"

prep nopin NOPIN; out=$(run n100 "$GOOD"); rc=$?
check "a missing pin file fails the build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

prep emptypin '# only comments, no version
'; out=$(run n100 "$GOOD"); rc=$?
check "a pin with no version line fails the build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

prep twopin "$PIN_VERSION
2026.09.4-dev.126
"; out=$(run n100 "$GOOD"); rc=$?
check "a pin naming two versions fails the build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

prep vpin "v$PIN_VERSION
"; out=$(run n100 "$GOOD"); rc=$?
check "a leading 'v' fails the build (the tag is bare CalVer)" \
	"$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

prep junkpin 'latest
'; out=$(run n100 "$GOOD"); rc=$?
check "a non-CalVer pin fails the build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"

# The case the issue exists for: the fetch does not work, and the image must
# NOT be finished without the descriptor.
prep nofetch '2026.01.1
'; out=$(run n100 "$GOOD"); rc=$?
check "a failed fetch fails the build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"
case "$out" in *"could not fetch"*) echo "ok   — and says the fetch is what failed" ;;
	*) echo "FAIL — and says the fetch is what failed: got '$out'"; fails=$((fails + 1)) ;; esac
case "$out" in *595*) echo "ok   — and points at why an unbaked image is not acceptable" ;;
	*) echo "FAIL — and points at why an unbaked image is not acceptable: got '$out'"; fails=$((fails + 1)) ;; esac

# Half a release: manifest.json present, the signature missing — every firewall
# release before 2026.09.4-dev.127 looks exactly like this.
HALF="$TMP/releases-half"; publish "$HALF" "$PIN_VERSION" "$PIN_VERSION" leaf
rm -f "$HALF/$PIN_VERSION/manifest.json.sig"
prep nosig "$PIN_VERSION"; out=$(run n100 "$HALF"); rc=$?
check "a release with no manifest.json.sig fails the build" \
	"$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

# Signed by a publisher this image does not trust.
BAD="$TMP/releases-badsig"; publish "$BAD" "$PIN_VERSION" "$PIN_VERSION" leaf-other
prep badsig "$PIN_VERSION"; out=$(run n100 "$BAD"); rc=$?
check "a signature from an untrusted root fails the build" \
	"$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

# Correctly signed, for a DIFFERENT release than the pin names: installing it
# would silently defeat the pin.
WRONG="$TMP/releases-wrongver"; publish "$WRONG" "$PIN_VERSION" "2026.09.4-dev.126" leaf
prep wrongver "$PIN_VERSION"; out=$(run n100 "$WRONG"); rc=$?
check "a manifest naming another version fails the build" \
	"$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

# No trust root in the target: there is nothing to verify against, and an
# unverified descriptor is not going in a PUBLISHED image. Whether that stops
# the build is DECLARED by the caller, not inferred from the tree.
#
# The first cut of this feature died here unconditionally, and failed four
# unrelated cases in test/rootfs-shadow-test.sh -- that suite hands post-build
# a minimal fixture tree with no trust root, for reasons that have nothing to
# do with the firewall. release.yml's build job injects a trust root
# unconditionally, so only a local build or a fixture ever lacks one.
prep noca "$PIN_VERSION" NOCA
out=$(RASPUTIN_REQUIRE_FIREWALL_MANIFEST=1 run n100 "$GOOD"); rc=$?
check "a missing trust root fails a REQUIRED build" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "  and bakes nothing" "$(baked)" "no"

prep noca2 "$PIN_VERSION" NOCA; out=$(run n100 "$GOOD"); rc=$?
check "without the requirement it SKIPS instead of failing" "$rc" "0"
check "  and still bakes nothing" "$(baked)" "no"
case "$out" in
	*"SKIPPING the firewall manifest bake"*) echo "ok   — and says loudly what that image will lack" ;;
	*) echo "FAIL — and says loudly what that image will lack: got '$out'"; fails=$((fails + 1)) ;;
esac

echo
echo "4. the wiring"

grep -q 'usr/share/rasputin/firewall' "$POSTBUILD" \
	&& echo "ok   — post-build installs to the contract path the api reads" \
	|| { echo "FAIL — post-build installs to the contract path the api reads"; fails=$((fails + 1)); }
# Never "latest": that is the failure this pin exists to prevent, and it would
# pass every case above.
# The requirement has to actually be declared where published images are built.
grep -q 'RASPUTIN_REQUIRE_FIREWALL_MANIFEST: "1"' "$ROOT/.github/workflows/release.yml" \
	&& echo "ok   — release.yml requires the bake for published images" \
	|| { echo "FAIL — release.yml requires the bake for published images"; fails=$((fails + 1)); }
grep -q 'releases/latest' "$POSTBUILD" \
	&& { echo "FAIL — post-build must never fetch the LATEST firewall release"; fails=$((fails + 1)); } \
	|| echo "ok   — post-build fetches only the pinned tag, never 'latest'"
grep -q 'firewall-manifest-test\.sh' "$CI" \
	&& echo "ok   — CI runs this test" \
	|| { echo "FAIL — CI runs this test"; fails=$((fails + 1)); }

echo
if [ "$fails" -eq 0 ]; then echo "firewall-manifest-test: all checks passed"; exit 0; fi
echo "firewall-manifest-test: $fails check(s) failed"; exit 1
