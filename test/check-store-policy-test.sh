#!/bin/sh
#
# Tests for board/rasputin/common/check-store-policy.sh, the post-build guard
# that refuses an image whose secrets store would fail its first start for want
# of its policy text (geekdojo/geekdojo-brain#804, TC-804-12).
#
# Why. A policy file init.json names but the image lacks fails self-init after
# its marker, and that store never unseals; the build is the last place to
# stop it. So the guard runs over a good scratch tree, which must pass, and
# over one variant per failure, each of which must exit 1 with a sentence
# naming the file or the difference.
#
# The good tree uses the overlay's real init.json, so the files the guard
# looks for are the ones the shipped config names.
#
# Shells: each shell in TEST_SHELLS (default: sh, dash and bash where
# installed), plus `busybox sh` when busybox is installed. REQUIRE_BUSYBOX=1
# (CI sets it) makes a missing busybox a failure.
#
# TC-805-25: the good tree carries exactly the four policy files init.json
# names since geekdojo-brain#805 added rasputin-provisioner and
# rasputin-bindable (the #805 PINS of TC-804-12).
#
# Run:  sh test/check-store-policy-test.sh
set -u
LC_ALL=C
export LC_ALL

if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAILED: REQUIRE_BUSYBOX=1 but busybox is not installed." >&2
	exit 1
fi

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
GUARD="$ROOT/board/rasputin/common/check-store-policy.sh"
INIT="$ROOT/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao/init.json"
for f in "$GUARD" "$INIT" "$ROOT/scripts/store-policy-drift.sh"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing." >&2; exit 1; }
done

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
fi
command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0 fail=0 SH=""
ok() {
	if [ "$2" = 0 ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }

PD=usr/share/rasputin/openbao-policy
# good — a target holding the overlay's init.json and all four policy files, and an
# extracted tarball holding the same files.
good() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	T="$W/target" S="$W/rasputin-api-2099.01.0"
	mkdir -p "$T/etc/rasputin/openbao" "$T/$PD" "$S/openbao-policy"
	cp "$INIT" "$T/etc/rasputin/openbao/init.json"
	printf 'path "rasputin-secrets/data/apps/*" {\n  capabilities = ["read"]\n}\n' > "$T/$PD/rasputin-api.hcl"
	printf 'path "sys/rotate/root" {\n  capabilities = ["update", "sudo"]\n}\n' > "$T/$PD/rasputin-seal-rotate.hcl"
	printf 'path "auth/cert/certs/" {\n  capabilities = ["list"]\n}\n' > "$T/$PD/rasputin-provisioner.hcl"
	printf 'path "auth/token/lookup-self" {\n  capabilities = ["read"]\n}\n' > "$T/$PD/rasputin-bindable.hcl"
	cp "$T/$PD"/*.hcl "$S/openbao-policy/"
}
guard() {
	case "$SH" in
		busybox_sh) busybox sh "$GUARD" "$@" > "$W/out" 2> "$W/err" ;;
		*) "$SH" "$GUARD" "$@" > "$W/out" 2> "$W/err" ;;
	esac
	RC=$?
}
# refused LABEL NEEDLE — exit 1, and stderr names NEEDLE.
refused() {
	ok "$1: exits 1" "$(yes_if test "$RC" = 1)" "rc=$RC $(cat "$W/out" "$W/err")"
	ok "$1: says '$2'" "$(yes_if grep -qF -- "$2" "$W/err")" "$(cat "$W/err")"
	ok "$1: says nothing passed" "$(yes_if test ! -s "$W/out")" "$(cat "$W/out")"
}

cases() {
	good; guard "$T" "$S"
	ok "the good tree passes" "$(yes_if test "$RC" = 0)" "rc=$RC $(cat "$W/err")"
	ok "the good tree: it says so" "$(yes_if grep -qF 'carries every policy file init.json names' "$W/out")" "$(cat "$W/out")"

	good; rm "$T/$PD/rasputin-seal-rotate.hcl"; guard "$T" "$S"
	refused "a named file absent" "The policy file /$PD/rasputin-seal-rotate.hcl that init.json names is not in the image, so the store's first start would fail and it would never unseal."

	good; : > "$T/$PD/rasputin-api.hcl"; : > "$S/openbao-policy/rasputin-api.hcl"; guard "$T" "$S"
	refused "a named file empty (in the tarball too)" "The policy file /$PD/rasputin-api.hcl that init.json names is empty in the image, so the store would initialise with a policy that grants nothing."

	good; sed 's|/usr/share/rasputin/openbao-policy/|/usr/share/rasputin/elsewhere/|' "$INIT" > "$T/etc/rasputin/openbao/init.json"; guard "$T" "$S"
	refused "init.json naming no policy file" "names no policy file under /$PD, so the store would initialise with no policy."

	good; printf '#' >> "$T/$PD/rasputin-api.hcl"; guard "$T" "$S"
	refused "the image copy differing from the tarball's" "The policy file rasputin-api.hcl differs between $T/$PD and $S/openbao-policy."
	ok "the image copy differing: the closing sentence names both copies" \
		"$(yes_if grep -qF "The image's policy text in /$PD is not the rasputin-api tarball's ($S/openbao-policy)" "$W/err")" "$(cat "$W/err")"

	good; printf 'x\n' > "$T/$PD/rasputin-extra.hcl"; guard "$T" "$S"
	refused "an extra image file the tarball lacks" "The policy file rasputin-extra.hcl is in $T/$PD but missing from $S/openbao-policy."

	# TC-805-25: each policy file #805 added to init.json is required too.
	for _f in rasputin-provisioner rasputin-bindable; do
		good; rm "$T/$PD/$_f.hcl" "$S/openbao-policy/$_f.hcl"; guard "$T" "$S"
		refused "TC-805-25 $_f.hcl absent from image and tarball" "The policy file /$PD/$_f.hcl that init.json names is not in the image, so the store's first start would fail and it would never unseal."
	done

	good; rm -r "$S/openbao-policy"; guard "$T" "$S"
	refused "a tarball with no openbao-policy/" "The policy directory $S/openbao-policy cannot be read"

	good; rm "$T/etc/rasputin/openbao/init.json"; guard "$T" "$S"
	refused "no init.json" "The store's self-init config $T/etc/rasputin/openbao/init.json is missing"

	good; guard "$T"
	ok "one argument: exits 2 with a usage sentence" "$(yes_if eval 'test "$RC" = 2 && grep -qF "Usage: " "$W/err"')" "rc=$RC $(cat "$W/err")"
}

echo "check-store-policy tests, shells:$TEST_SHELLS"
for SH in $TEST_SHELLS; do cases; done
case "$TEST_SHELLS" in
	*busybox_sh*) SH=harness; ok "the busybox row ran" 0 ;;
	*) SH=harness; [ "${REQUIRE_BUSYBOX:-0}" = 1 ] && ok "the busybox row ran" 1 ;;
esac
echo "check-store-policy tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
