#!/bin/sh
#
# store-guest-checks.sh — the secrets store checks test/update-smoke.sh runs
# ON THE GUEST in boot 2, as root, over SSH (geekdojo/geekdojo-brain#804,
# TC-804-21 and TC-804-22). Copied to the guest and run; never sourced.
#
#   sh store-guest-checks.sh checks   one KEY=VALUE line per fact, for the host
#                                     to assert; run twice, around an
#                                     api-pulled restart of the store
#   sh store-guest-checks.sh scan     the token scan of the persistent
#                                     partition and the journal
#
# TOKENS STAY ON THE GUEST. Each login is `bao login -no-store -token-only`,
# so no token helper file is written; the token goes to a 0600 file under
# $OUT (tmpfs) and reaches later calls as BAO_TOKEN in that one command's
# environment. Nothing printed holds a token: the scan prints counts only.
#
# Inputs, with the image's defaults; the harness sets OUT and ROTATE_LEAF:
#   CA           the store CA (the api writes it)
#   API_LEAF     the api's own client leaf, <API_LEAF>.pem and .key (#758)
#   ROTATE_LEAF  a store-CA leaf with CommonName rasputin-seal-rotate, minted
#                by the harness, <ROTATE_LEAF>.pem and .key
#   OUT          where the tokens and the written value are kept (tmpfs)
#   PERSIST      the persistent partition the scan reads
#
# Needs on the guest: bao, grep, find, ls, cat, od, tr, cut, stat, journalctl.
set -u
umask 077

export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
CA="${CA:-/var/lib/rasputin/trust/store-ca.pem}"
API_LEAF="${API_LEAF:-/var/lib/rasputin/tls/openbao-client/leaf}"
ROTATE_LEAF="${ROTATE_LEAF:?ROTATE_LEAF must name the harness rasputin-seal-rotate leaf}"
OUT="${OUT:?OUT names a tmpfs directory for the tokens}"
PERSIST="${PERSIST:-/var/lib/rasputin}"
RECORD="${RECORD:-/run/rasputin-store-init/outcome}"
PRECORD="${PRECORD:-/run/rasputin-store-provision/outcome}"
AUDIT_LOG="${AUDIT_LOG:-/var/lib/rasputin/openbao-audit/audit.log}"
BOOTID_SRC="${BOOTID_SRC:-/proc/sys/kernel/random/boot_id}"
mkdir -p "$OUT"

# one LINE — the command's output on one line.
one() { tr -d '\r' | tr '\n' ' ' | sed 's/  */ /g; s/ $//'; }

# login LEAF ROLE FILE — a token for ROLE with LEAF, into FILE. 0 on success.
login() {
	bao login -no-store -token-only -method=cert -ca-cert="$CA" \
		-client-cert="$1.pem" -client-key="$1.key" name="$2" >"$3" 2>"$3.err"
	[ -s "$3" ]
}
# as FILE CMD... — CMD with FILE's token in its environment only.
as() { _as=$1; shift; BAO_TOKEN=$(cat "$_as") "$@"; }
# code CMD... — 403 when bao reports a permission refusal, else the exit status.
code() {
	_c_out=$("$@" 2>&1); _c_rc=$?
	case "$_c_out" in *"Code: 403"*) echo 403 ;; *) echo "rc$_c_rc" ;; esac
}

checks() {
	echo "status=$(bao status -format=json -ca-cert="$CA" -client-cert="$API_LEAF.pem" -client-key="$API_LEAF.key" 2>&1 | one)"
	if login "$API_LEAF" rasputin-api "$OUT/api.token"; then
		echo "api_login=ok"
		# lookup-self's policies only: the whole lookup carries the token's id.
		echo "api_policies=$(as "$OUT/api.token" bao token lookup -format=json -field=policies -ca-cert="$CA" -client-cert="$API_LEAF.pem" -client-key="$API_LEAF.key" 2>&1 | one | tr -d ' ')"
		[ -s "$OUT/sentinel" ] || od -An -N12 -tx1 /dev/urandom | tr -d ' \n' >"$OUT/sentinel"
		printf '{"data":{"v":"%s"}}' "$(cat "$OUT/sentinel")" \
			| as "$OUT/api.token" bao write -ca-cert="$CA" -client-cert="$API_LEAF.pem" -client-key="$API_LEAF.key" \
				rasputin-secrets/data/apps/update-smoke - >/dev/null 2>"$OUT/kv.err"
		echo "kv_write=rc$?"
		_got=$(as "$OUT/api.token" bao read -field=data -format=json -ca-cert="$CA" -client-cert="$API_LEAF.pem" -client-key="$API_LEAF.key" \
			rasputin-secrets/data/apps/update-smoke 2>&1 | one)
		_want=$(cat "$OUT/sentinel")
		case "$_got" in *"\"v\": \"$_want\""*|*"\"v\":\"$_want\""*) echo "kv_read=match" ;; *) echo "kv_read=nomatch" ;; esac
		_tls="-ca-cert=$CA -client-cert=$API_LEAF.pem -client-key=$API_LEAF.key"
		# shellcheck disable=SC2086 # _tls is three flags, split on purpose
		{
			printf 'path "sys/*" {\n  capabilities = ["sudo"]\n}\n' >"$OUT/injected.hcl"
			echo "deny_policy_write=$(as "$OUT/api.token" code bao policy write $_tls update-smoke-injected "$OUT/injected.hcl")"
			echo "deny_sys_mounts=$(as "$OUT/api.token" code bao read $_tls sys/mounts)"
			echo "deny_identity_entity=$(as "$OUT/api.token" code bao write $_tls identity/entity name=update-smoke)"
			echo "deny_token_create=$(as "$OUT/api.token" code bao token create $_tls -policy=rasputin-seal-rotate)"
		}
	else
		echo "api_login=fail $(one <"$OUT/api.token.err")"
	fi
	# The rotation policy grants nothing but sys/rotate/root, not even
	# lookup-self, so its policies are read from the login answer, which is
	# kept in a 0600 file and never printed whole.
	if bao login -no-store -format=json -method=cert -ca-cert="$CA" -client-cert="$ROTATE_LEAF.pem" \
		-client-key="$ROTATE_LEAF.key" name=rasputin-seal-rotate >"$OUT/rotate.login" 2>"$OUT/rotate.err"; then
		echo "rotate_login=ok"
		one <"$OUT/rotate.login" | sed -n 's/.*"client_token": *"\([^"]*\)".*/\1/p' >"$OUT/rotate.token"
		echo "rotate_policies=$(one <"$OUT/rotate.login" | sed -n 's/.*"token_policies": *\(\[[^]]*\]\).*/\1/p' | tr -d ' ')"
	else
		echo "rotate_login=fail $(one <"$OUT/rotate.err")"
	fi
	rm -f "$OUT/rotate.login"
	echo "leaf_key=$(ls -ln "$API_LEAF.key" 2>&1 | awk '{ print $1, $3, $4 }')"
	echo "audit_hmac=$(grep -c 'hmac-sha256:' "$AUDIT_LOG" 2>&1)"
	echo "audit_value=$(grep -c -F -f "$OUT/sentinel" "$AUDIT_LOG" 2>&1)"
	echo "record_outcome=$(sed -n 's/^outcome=//p' "$RECORD" 2>&1)"
	_b=$(cat "$BOOTID_SRC" 2>/dev/null)
	if [ -n "$_b" ] && grep -qx "boot_id=$_b" "$RECORD" 2>/dev/null; then echo "record_boot=this"; else echo "record_boot=other"; fi
	echo "record_lines=$(wc -l <"$RECORD" 2>/dev/null | tr -d ' ')"
	echo "record_sum=$(cksum <"$RECORD" 2>/dev/null | one)"
	echo "store_init_lines=$(journalctl -b -u openbao.service --no-pager -o cat 2>/dev/null | grep -c 'rasputin-store-init: outcome=')"
	# The store provisioner's record and lines (geekdojo/geekdojo-brain#805,
	# TC-805-36): the record's mode and owner, its keys in order, its outcome,
	# and this boot's outcome lines by kind.
	echo "prov_record_mode=$(stat -c '%a %u:%g' "$PRECORD" 2>&1)"
	echo "prov_record_keys=$(cut -d= -f1 "$PRECORD" 2>/dev/null | tr '\n' ',')"
	echo "prov_record_outcome=$(sed -n 's/^outcome=//p' "$PRECORD" 2>&1)"
	_pj=$(journalctl -b -u rasputin-store-provision.service --no-pager -o cat 2>/dev/null)
	echo "prov_unchanged_lines=$(printf '%s\n' "$_pj" | grep -c 'rasputin-store-provision: outcome=unchanged')"
	echo "prov_failed_lines=$(printf '%s\n' "$_pj" | grep -c 'rasputin-store-provision: outcome=failed')"
}

# The token shapes: Vault's hv[sbr]. form, which the test plan names, and
# OpenBao's own [sbr]. form, which is what v2.7.1 issues (s. plus 24
# characters, measured).
V_RE='hv[sbr]\.[A-Za-z0-9]{24}'
B_RE='(^|[^A-Za-z0-9])[sbr]\.[A-Za-z0-9]{24}([^A-Za-z0-9]|$)'

scan() {
	# grep must read binary files as text, or a token in the SQLite database or
	# a journal file is skipped as "binary file matches" and counted as none.
	if ! printf 'x\000y\n' | grep -a -q x 2>/dev/null; then
		echo "grep_a=unsupported"
		return
	fi
	echo "grep_a=ok"
	# One value per line: the token files and the value carry no newline.
	for _n in api.token rotate.token sentinel; do
		[ -s "$OUT/$_n" ] && { cat "$OUT/$_n"; echo; }
	done >"$OUT/needles"
	echo "needles=$(grep -c '' "$OUT/needles")"
	# The control: the shapes match the tokens this run holds.
	echo "control_bao_shape=$(grep -c -E "$B_RE" "$OUT/needles")"
	# Every regular file on the persistent partition, binary files included,
	# except the container image stores: docker/ and containerd/ hold image
	# layers baked into the image at build time or pulled by digest, which no
	# token issued at run time reaches, and their size would dominate the run.
	find "$PERSIST" -xdev -type f ! -path "$PERSIST/docker/*" ! -path "$PERSIST/containerd/*" >"$OUT/files" 2>/dev/null
	echo "files=$(grep -c '' "$OUT/files")"
	_v=0 _bb=0 _x=0
	while IFS= read -r f; do
		grep -a -q -E "$V_RE" "$f" 2>/dev/null && _v=$((_v + 1))
		grep -a -q -E "$B_RE" "$f" 2>/dev/null && _bb=$((_bb + 1))
		grep -a -q -F -f "$OUT/needles" "$f" 2>/dev/null && _x=$((_x + 1))
	done <"$OUT/files"
	echo "files_vault_shape=$_v files_bao_shape=$_bb files_exact=$_x"
	# Every boot's journal, read through journalctl so compressed fields are
	# searched decompressed.
	journalctl --no-pager -o cat >"$OUT/journal" 2>/dev/null
	echo "journal_lines=$(grep -c '' "$OUT/journal")"
	echo "journal_vault_shape=$(grep -a -c -E "$V_RE" "$OUT/journal") journal_bao_shape=$(grep -a -c -E "$B_RE" "$OUT/journal") journal_exact=$(grep -a -c -F -f "$OUT/needles" "$OUT/journal")"
	rm -f "$OUT/journal" "$OUT/files"
}

case "${1:-}" in
	checks) checks ;;
	scan) scan ;;
	*) echo "usage: store-guest-checks.sh checks|scan" >&2; exit 2 ;;
esac
