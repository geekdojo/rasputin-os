#!/bin/sh
# Static assertions on the secrets store's main config, openbao.hcl, and on how
# the image enables the store (geekdojo/geekdojo-brain#756).
#
# Why. Every way to get this file wrong is silent at build time and most are
# silent at run time too: a listener on 0.0.0.0 still answers on loopback, an
# unauthenticated-endpoint option at the top level is ignored without a word
# (D679-05), a second CA in the client trust lets the controlplane CA's leaves
# in, a seal stanza here would pin a key id into an image every cluster shares
# (S10), and log_level = "trace" works fine and logs too much. So the exact key
# set of each scope is pinned, each value is checked, the credential paths are
# derived from the unit's own LoadCredential= lines rather than written here,
# and the post-build wants link is checked as the one thing that enables the
# store.
#
# The file is read only through test/lib/hcl-keys.sh (hcl_get, hcl_keys), the
# unit only through test/lib/unit-directives.sh (directives). This script
# parses neither format itself. The tie between this file's listener and the
# api's address lives in test/api-store-wiring-test.sh alone.
#
# Negative controls. The checker runs over scratch copies of the tree, each
# with one injection, and must refuse every one, naming the injected key or
# line (TC-756-06). The libraries it reads with are table-tested here too
# (TC-756-07).
#
# This is a static test: whether bao accepts the file is
# test/store-unit-functional.sh, which runs it byte for byte.
#
# Run:  sh test/store-config-test.sh [ROOT]
#       ROOT is the tree to check; it defaults to this repo.
set -u

ROOT=${1:-$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)}
REL_OVERLAY=board/rasputin/common/rootfs-overlay
REL_UNIT=$REL_OVERLAY/etc/systemd/system/openbao.service
REL_TMPFILES=$REL_OVERLAY/usr/lib/tmpfiles.d/rasputin.conf
REL_POSTBUILD=board/rasputin/common/post-build.sh
REL_MK=package/openbao/openbao.mk
LIB="$ROOT/test/lib"

# --- fail closed, before anything else (TC-756-08) -----------------------------
for f in "$ROOT/$REL_UNIT" "$ROOT/$REL_POSTBUILD" "$ROOT/$REL_TMPFILES" "$ROOT/$REL_MK"; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing, so the store's config cannot be checked."; exit 1; }
done
for f in checks.sh hcl-keys.sh unit-directives.sh mk-var.sh listen-sockets.sh; do
	[ -f "$LIB/$f" ] || { echo "FAILED: the test library $LIB/$f is missing, so this test cannot run."; exit 1; }
done
command -v make >/dev/null 2>&1 \
	|| { echo "FAILED: GNU make is not on PATH, and the openbao user is read from openbao.mk with it."; exit 1; }
command -v jq >/dev/null 2>&1 \
	|| { echo "FAILED: jq is not on PATH, and the store's self-init config (init.json) is read with it."; exit 1; }

. "$LIB/checks.sh"
. "$LIB/hcl-keys.sh"
. "$LIB/unit-directives.sh"
. "$LIB/mk-var.sh"
. "$LIB/listen-sockets.sh"

# values and words D SECTION KEY — the shared lib, test/lib/unit-directives.sh.
# configs D — ExecStart's -config= paths, in order.
configs() { words "$1" Service ExecStart | sed -n 's/^-config=//p'; }

CONFIG=$(configs "$(directives "$ROOT/$REL_UNIT")" | head -1)
[ -n "$CONFIG" ] \
	|| { echo "FAILED: the ExecStart of $ROOT/$REL_UNIT names no -config=, so there is no store config to check."; exit 1; }
[ -f "$ROOT/$REL_OVERLAY$CONFIG" ] \
	|| { echo "FAILED: the store's config $ROOT/$REL_OVERLAY$CONFIG (ExecStart's first -config) is missing, so it cannot be checked."; exit 1; }
# The self-init config is ExecStart's second -config (geekdojo-brain#804).
INIT=$(configs "$(directives "$ROOT/$REL_UNIT")" | sed -n 2p)
case "$INIT" in /etc/*) ;; *) echo "FAILED: ExecStart's second -config ($INIT) is not a file under /etc, so there is no self-init config to check."; exit 1 ;; esac
[ -f "$ROOT/$REL_OVERLAY$INIT" ] \
	|| { echo "FAILED: the store's self-init config $ROOT/$REL_OVERLAY$INIT (ExecStart's second -config) is missing, so it cannot be checked."; exit 1; }

# The static user, from the package (S7). Fields: name uid group gid ...
USERS=$(mk_var "$ROOT/$REL_MK" OPENBAO_USERS) || { echo "FAILED: could not read OPENBAO_USERS from $ROOT/$REL_MK."; exit 1; }
set -f
# shellcheck disable=SC2086 # the fields of OPENBAO_USERS; -f as field 5 is *
set -- $USERS
set +f
BAO_UID=$2

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM

# The post-build line that enables the store, exactly as it must read.
# shellcheck disable=SC2016 # $TARGET_DIR is post-build.sh's, literally
LINK='ln -sf /etc/systemd/system/openbao.service "$TARGET_DIR/etc/systemd/system/multi-user.target.wants/openbao.service"'
# shellcheck disable=SC2016
WANTS_DIR='mkdir -p "$TARGET_DIR/etc/systemd/system/multi-user.target.wants"'

# --- the checker -------------------------------------------------------------------
#
# verify R — checks the tree R; prints an ok or FAIL line per assertion and
# returns non-zero on any failure. A subshell, so its $fails is its own.
verify() (
	fails=0
	R=$1
	U="$R/$REL_UNIT"
	NAME=$(basename "$U")
	D=$(directives "$U")
	H="$R/$REL_OVERLAY$(configs "$D" | head -1)"
	CREDS="/run/credentials/$NAME"

	# setof LABEL GOT WANT — GOT and WANT (one entry per line) are the same
	# entries, duplicates counted. The failure names what is extra and missing.
	setof() {
		printf '%s\n' "$2" | sed '/^$/d' | sort >"$SCRATCH/set.got"
		printf '%s\n' "$3" | sed '/^$/d' | sort >"$SCRATCH/set.want"
		_extra=$(comm -23 "$SCRATCH/set.got" "$SCRATCH/set.want" | tr '\n' '|')
		_missing=$(comm -13 "$SCRATCH/set.got" "$SCRATCH/set.want" | tr '\n' '|')
		check "$1" "$(yes_if [ -z "$_extra$_missing" ])" "unexpected: ${_extra:-none}; missing: ${_missing:-none}"
	}
	# keys BLOCK — hcl_keys' list, or its sentence (which matches nothing).
	keys() { hcl_keys "$H" "$1" 2>&1; }
	# value_is LABEL BLOCK KEY WANT — hcl_get reads exactly WANT.
	value_is() {
		_v=$(hcl_get "$H" "$2" "$3" 2>&1); _rc=$?
		_st=1
		[ "$_rc" -eq 0 ] && [ "$_v" = "$4" ] && _st=0
		check "$1" "$_st" "got: $_v"
	}
	# cred SOURCE — the name of the LoadCredential= whose source is SOURCE.
	cred() { values "$D" Service LoadCredential | awk -F: -v s="$1" '$2 == s { print $1 }'; }
	LISTENER='listener "tcp"'

	echo "  -- the exact keys of each scope (TC-756-01)"
	# Since geekdojo-brain#804 the top level also holds the one audit stanza.
	setof "TC-756-01 the top level holds exactly api_addr, disable_clustering, ui, log_level, one listener \"tcp\", one storage \"pebbledb\" and one audit \"file\" \"rasputin\"" \
		"$(keys '')" 'api_addr
disable_clustering
ui
log_level
listener "tcp" {
storage "pebbledb" {
audit "file" "rasputin" {'
	setof "TC-756-01 the listener \"tcp\" block holds exactly address, the three TLS files, the client-cert requirement and the two disable_unauthed_* options" \
		"$(keys "$LISTENER")" 'address
tls_cert_file
tls_key_file
tls_client_ca_file
tls_require_and_verify_client_cert
disable_unauthed_rekey_endpoints
disable_unauthed_generate_root_endpoints'
	setof "TC-756-01 the storage \"pebbledb\" block holds exactly path" "$(keys 'storage "pebbledb"')" 'path'

	echo "  -- the values (TC-756-02)"
	value_is "TC-756-02 listener \"tcp\" address = 127.0.0.1:8200" "$LISTENER" address 127.0.0.1:8200
	_addr=$(hcl_get "$H" "$LISTENER" address 2>/dev/null)
	value_is "TC-756-02 top level api_addr = https://<the listener's address> (https://${_addr:-?})" '' api_addr "https://${_addr:-<no listener address>}"
	value_is "TC-756-02 listener \"tcp\" tls_require_and_verify_client_cert = true" "$LISTENER" tls_require_and_verify_client_cert true
	value_is "TC-756-02 listener \"tcp\" disable_unauthed_rekey_endpoints = true" "$LISTENER" disable_unauthed_rekey_endpoints true
	value_is "TC-756-02 listener \"tcp\" disable_unauthed_generate_root_endpoints = true" "$LISTENER" disable_unauthed_generate_root_endpoints true
	value_is "TC-756-02 top level disable_clustering = true" '' disable_clustering true
	value_is "TC-756-02 top level ui = false" '' ui false
	value_is "TC-756-02 top level log_level = info" '' log_level info

	echo "  -- the paths come from the unit and the tmpfiles lines (TC-756-03)"
	check "TC-756-03 the file checked is ExecStart's first -config, in the overlay" "$(yes_if [ -f "$H" ])" "no file at $H"
	for pair in tls_cert_file:/var/lib/rasputin/tls/openbao-server/leaf.pem \
		tls_key_file:/var/lib/rasputin/tls/openbao-server/leaf.key \
		tls_client_ca_file:/var/lib/rasputin/trust/store-ca.pem; do
		_k=${pair%%:*} _src=${pair#*:}
		_name=$(cred "$_src")
		if [ -z "$_name" ]; then
			check "TC-756-03 listener \"tcp\" $_k is the copy of the credential from $_src" 1 "no LoadCredential= in $NAME has the source $_src"
			continue
		fi
		value_is "TC-756-03 listener \"tcp\" $_k is the copy of the credential from $_src ($CREDS/$_name)" "$LISTENER" "$_k" "$CREDS/$_name"
	done
	_path=$(hcl_get "$H" 'storage "pebbledb"' path 2>&1)
	check "TC-756-03 storage \"pebbledb\" path ($_path) is one of the unit's ReadWritePaths" "$(yes_if contains "
$_path
" "
$(words "$D" Service ReadWritePaths)
")" "ReadWritePaths: $(words "$D" Service ReadWritePaths | tr '\n' ' ')"
	check "TC-756-03 the tmpfiles lines create $_path, owned by OPENBAO_USERS' uid ($BAO_UID)" \
		"$(yes_if awk -v p="$_path" -v u="$BAO_UID" '$1 == "d" && $2 == p && $4 == u { found = 1 } END { exit !found }' "$R/$REL_TMPFILES")" \
		"no 'd $_path ... $BAO_UID' line in $REL_TMPFILES"

	echo "  -- no secret, no seal, no log-level override (TC-756-04)"
	_pem=$(grep -n -e '-----BEGIN' "$H" || true)
	check "TC-756-04 no -----BEGIN anywhere in the file, comments included" "$(yes_if [ -z "$_pem" ])" "found: $(printf '%s' "$_pem" | tr '\n' '|')"
	_top=$(keys '')
	_seal=$(printf '%s\n' "$_top" | grep -E '^seal( |$)' || true)
	check "TC-756-04 no seal block" "$(yes_if [ -z "$_seal" ])" "found: $_seal"
	_all=$(printf '%s\n' "$_top" | grep -v ' {$')
	while IFS= read -r _b; do
		[ -n "$_b" ] && _all="$_all
$(keys "${_b% \{}")"
	done <<-EOF
	$(printf '%s\n' "$_top" | grep ' {$')
	EOF
	_bad=$(printf '%s\n' "$_all" | grep -E '^(current_key|current_key_id|token)$' || true)
	check "TC-756-04 no current_key, current_key_id or token key in any scope" "$(yes_if [ -z "$_bad" ])" \
		"found: $(printf '%s' "$_bad" | tr '\n' '|')"
	# Since geekdojo-brain#804 init.json is the second -config, so the seal
	# fragment is the last.
	_seal_name=$(cred /var/lib/rasputin/openbao-seal/seal.hcl)
	_last=$(configs "$D" | tail -n 1)
	_st=1
	[ -n "$_seal_name" ] && [ "$_last" = "$CREDS/$_seal_name" ] && _st=0
	check "TC-756-04 ExecStart's last -config is the seal.hcl credential's copy ($CREDS/${_seal_name:-?})" \
		"$_st" "last -config: ${_last:-none}"
	_ll=$(words "$D" Service ExecStart | grep -e '^-log-level' || true)
	check "TC-756-04 ExecStart has no -log-level" "$(yes_if [ -z "$_ll" ])" "found: $_ll"
	_env=$(printf '%s\n' "$D" | grep BAO_LOG_LEVEL || true)
	check "TC-756-04 the unit sets no BAO_LOG_LEVEL" "$(yes_if [ -z "$_env" ])" "found: $(printf '%s' "$_env" | tr '\n' '|')"

	echo "  -- enabled by one post-build link, and nothing else (TC-756-05)"
	_pb="$R/$REL_POSTBUILD"
	_lines=$(grep -n 'openbao\.service' "$_pb" | grep -v '^[0-9]*:[[:space:]]*#' || true)
	_n=0; [ -n "$_lines" ] && _n=$(printf '%s\n' "$_lines" | grep -c '')
	_ln_no=${_lines%%:*}
	_body=$(printf '%s' "${_lines#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
	_st=1
	[ "$_n" -eq 1 ] && [ "$_body" = "$LINK" ] && _st=0
	check "TC-756-05 post-build.sh has exactly one line naming openbao.service, the link into multi-user.target.wants/openbao.service (got $_n)" \
		"$_st" "lines: $(printf '%s' "$_lines" | tr '\n' '|')"
	_mk_no=$(grep -n -F -x "$WANTS_DIR" "$_pb" | head -1 | cut -d: -f1)
	_st=1
	[ -n "$_mk_no" ] && [ "$_n" -eq 1 ] && [ "$_mk_no" -lt "$_ln_no" ] && _st=0
	check "TC-756-05 the link comes after the mkdir -p of multi-user.target.wants (lines ${_mk_no:-none} and ${_ln_no:-none})" "$_st"
	_wants=$(find "$R/$REL_OVERLAY" -path '*.wants/openbao.service' 2>/dev/null)
	check "TC-756-05 no *.wants/openbao.service in the overlay" "$(yes_if [ -z "$_wants" ])" "$_wants"
	_install=$(grep -nE '^[[:space:]]*\[Install\]' "$U" || true)
	check "TC-756-05 the unit has no [Install] section" "$(yes_if [ -z "$_install" ])" "found: $_install"

	echo "  -- the audit stanza (TC-804-13 (1), (2))"
	AUDIT='audit "file" "rasputin"'
	setof "TC-804-13 the audit \"file\" \"rasputin\" block holds exactly one options block" "$(keys "$AUDIT")" 'options {'
	setof "TC-804-13 the audit options hold exactly file_path, mode, log_raw and hmac_accessor" \
		"$(keys "$AUDIT / options")" 'file_path
mode
log_raw
hmac_accessor'
	value_is "TC-804-13 audit mode = 0600" "$AUDIT / options" mode 0600
	value_is "TC-804-13 audit log_raw = false (every string value HMACed)" "$AUDIT / options" log_raw false
	value_is "TC-804-13 audit hmac_accessor = true" "$AUDIT / options" hmac_accessor true
	_fp=$(hcl_get "$H" "$AUDIT / options" file_path 2>&1)
	check "TC-804-13 the audit file_path ($_fp) sits in one of the unit's ReadWritePaths directories" "$(yes_if contains "
$(dirname "$_fp")
" "
$(words "$D" Service ReadWritePaths)
")" "ReadWritePaths: $(words "$D" Service ReadWritePaths | tr '\n' ' ')"
	_init=$(printf '%s\n' "$_top" | grep -E '^initialize( |$)' || true)
	check "TC-804-13 openbao.hcl has no initialize stanza (self-init is init.json's)" "$(yes_if [ -z "$_init" ])" "found: $_init"

	echo "  -- the self-init config, init.json (TC-804-13 (3) to (6))"
	J="$R/$REL_OVERLAY$INIT"
	_ca_name=$(cred /var/lib/rasputin/trust/store-ca.pem)
	CA_PATH="$CREDS/${_ca_name:-<no store-ca.pem credential>}"
	# reqs — one "PATH<TAB>OPERATION" per request, in order.
	_reqs=$(jq -r '.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | "\(.path)\t\(.operation)"' "$J" 2>&1)
	# TC-805-24: four policies and three roles, the provisioner's added by
	# geekdojo-brain#805 (the #805 PINS of TC-804-13).
	check "TC-804-13 TC-805-24 init.json's requests are exactly the four policies, the mount, cert auth and the three roles, in order" \
		"$(yes_if [ "$(printf '%s\n' "$_reqs" | cut -f1)" = 'sys/policies/acl/rasputin-api
sys/policies/acl/rasputin-seal-rotate
sys/policies/acl/rasputin-provisioner
sys/policies/acl/rasputin-bindable
sys/mounts/rasputin-secrets
sys/auth/cert
auth/cert/certs/rasputin-api
auth/cert/certs/rasputin-seal-rotate
auth/cert/certs/rasputin-provisioner' ])" "got: $(printf '%s' "$_reqs" | cut -f1 | tr '\n' '|')"
	_ops=$(printf '%s\n' "$_reqs" | cut -f2 | sort -u)
	check "TC-804-13 every request's operation is update" "$(yes_if [ "$_ops" = update ])" "got: $(printf '%s' "$_ops" | tr '\n' '|')"
	_audit=$(printf '%s\n' "$_reqs" | cut -f1 | grep '^sys/audit' || true)
	check "TC-804-13 no request touches sys/audit (a failed one leaves a store that never unseals)" "$(yes_if [ -z "$_audit" ])" "found: $_audit"
	_af=$(jq '[.. | objects | select(has("allow_failure"))] | length' "$J" 2>&1)
	check "TC-804-13 no allow_failure anywhere" "$(yes_if [ "$_af" = 0 ])" "found $_af"
	_tok=$(jq '[.. | objects | select(has("token"))] | length' "$J" 2>&1)
	check "TC-804-13 no token field anywhere" "$(yes_if [ "$_tok" = 0 ])" "found $_tok"
	_env=$(jq -r '[.. | objects | select(has("eval_source")) | .eval_source | select(. != "file")] | unique | join(",")' "$J" 2>&1)
	check "TC-804-13 no env or other non-file source" "$(yes_if [ -z "$_env" ])" "found: $_env"
	# req PATH — the data of the request on PATH, compact.
	req() { jq -c --arg p "$1" '[.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | select(.path == $p) | .data] | if length == 1 then .[0] else "requests on that path: \(length)" end' "$J" 2>&1; }
	check "TC-804-13 the mount is kv version 2" \
		"$(yes_if [ "$(req sys/mounts/rasputin-secrets)" = '{"type":"kv","options":{"version":"2"}}' ])" "got: $(req sys/mounts/rasputin-secrets)"
	check "TC-804-13 cert auth is enabled" "$(yes_if [ "$(req sys/auth/cert)" = '{"type":"cert"}' ])" "got: $(req sys/auth/cert)"
	for _p in rasputin-api rasputin-seal-rotate rasputin-provisioner rasputin-bindable; do
		_want_pol=$(jq -cn --arg p "/usr/share/rasputin/openbao-policy/$_p.hcl" '{policy: {eval_type: "string", eval_source: "file", path: $p}}')
		check "TC-804-13 TC-805-24 policy $_p is read from /usr/share/rasputin/openbao-policy/$_p.hcl through a file source" \
			"$(yes_if [ "$(req "sys/policies/acl/$_p")" = "$_want_pol" ])" "got: $(req "sys/policies/acl/$_p")"
	done
	for _p in rasputin-api rasputin-seal-rotate rasputin-provisioner; do
		_want_role=$(jq -cn --arg n "$_p" --arg ca "$CA_PATH" '{certificate: {eval_type: "string", eval_source: "file", path: $ca}, allowed_common_names: [$n], token_policies: [$n], token_no_default_policy: true, token_ttl: "1h"}')
		check "TC-804-13 TC-805-24 role $_p: CN $_p only, policy $_p only, token_no_default_policy, token_ttl 1h, the store CA credential ($CA_PATH) as its certificate" \
			"$(yes_if [ "$(req "auth/cert/certs/$_p")" = "$_want_role" ])" "got: $(req "auth/cert/certs/$_p")"
	done
	_binders=$(jq -r '.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | select(((.data.token_policies // []) + (.data.policies // [])) | index("rasputin-seal-rotate")) | .path' "$J" 2>&1)
	check "TC-804-13 rasputin-seal-rotate is bound only by its own role" \
		"$(yes_if [ "$_binders" = auth/cert/certs/rasputin-seal-rotate ])" "bound by: $(printf '%s' "$_binders" | tr '\n' '|')"
	_bindable=$(jq -r '.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | select(((.data.token_policies // []) + (.data.policies // [])) | index("rasputin-bindable")) | .path' "$J" 2>&1)
	check "TC-805-24 rasputin-bindable is bound by no init.json role (only the provisioner's roles bind it)" \
		"$(yes_if [ -z "$_bindable" ])" "bound by: $(printf '%s' "$_bindable" | tr '\n' '|')"
	_roles=$(jq -r '[.initialize[] | to_entries[] | .value.request[] | to_entries[] | .value | select(.path | startswith("auth/cert/certs/"))] | length' "$J" 2>&1)
	check "TC-805-24 init.json has exactly three cert roles (got $_roles)" "$(yes_if [ "$_roles" = 3 ])"

	echo "  -- init.json is frozen; later items are provision.tsv's (TC-805-24)"
	_frozen=$(grep -c 'init.json is FROZEN from the store-arming' "$U" || true)
	check "TC-805-24 openbao.service's comment on init.json says it is frozen from the store-arming release on" "$(yes_if [ "$_frozen" = 1 ])" "found $_frozen"
	_pt="$R/$REL_OVERLAY/etc/rasputin/openbao/provision.tsv"
	_ptf=$(grep -c 'init.json beside this file is FROZEN from the store-arming release on' "$_pt" 2>/dev/null || true)
	check "TC-805-24 provision.tsv's header says init.json is frozen from the store-arming release on" "$(yes_if [ "$_ptf" = 1 ])" "found ${_ptf:-0} in $_pt"
	_items=$(grep -v -e '^#' -e '^[[:space:]]*$' "$_pt" 2>/dev/null || true)
	check "TC-805-24 the shipped provision.tsv holds no entry" "$(yes_if eval '[ -f "$_pt" ] && [ -z "$_items" ]')" "entries: $(printf '%s' "$_items" | tr '\n' '|')"
	_stray=$(jq -r --arg ca "$CA_PATH" '[.. | objects | select(.eval_source? == "file") | .path | select((startswith("/usr/share/rasputin/openbao-policy/") or . == $ca) | not)] | join(",")' "$J" 2>&1)
	check "TC-804-13 every file source is under /usr/share/rasputin/openbao-policy/ or is the store CA credential" \
		"$(yes_if [ -z "$_stray" ])" "outside: $_stray"

	[ "$fails" -eq 0 ]
)

echo "1. the shipped config and its wiring"
verify "$ROOT"; rc=$?
check "the shipped openbao.hcl, openbao.service and post-build.sh pass every check" "$rc"

# --- negative controls (TC-756-06) --------------------------------------------------
N=0
# tree — a scratch copy of the seven files verify reads. Sets T.
tree() {
	N=$((N + 1))
	T="$SCRATCH/t$N"
	for _rel in "$REL_UNIT" "$REL_TMPFILES" "$REL_POSTBUILD" "$REL_MK" "$REL_OVERLAY$CONFIG" "$REL_OVERLAY$INIT" \
		"$REL_OVERLAY/etc/rasputin/openbao/provision.tsv"; do
		mkdir -p "$(dirname "$T/$_rel")"
		cp "$ROOT/$_rel" "$T/$_rel"
	done
}
# edit FILE MODE [LINE] — "after:L" puts LINE after the line L, "replace:L" in
# its place (an empty LINE deletes L), "append" at the end. LINE may hold \n.
# The copy must change, or the control would prove nothing.
edit() {
	_f=$1 _mode=${2%%:*} _anchor=${2#*:} _line=${3:-}
	cp "$_f" "$_f.orig"
	awk -v m="$_mode" -v a="$_anchor" -v l="$_line" '
		$0 == a && m == "replace" { if (l != "") print l; next }
		{ print }
		$0 == a && m == "after" { print l }
		END { if (m == "append") print l }
	' "$_f.orig" >"$_f"
	if cmp -s "$_f" "$_f.orig"; then
		check "the control's edit changed $(basename "$_f") ($2)" 1 "the anchor line is not in the file"
		rm -f "$_f.orig"
		return 1
	fi
	rm -f "$_f.orig"
}
# refused LABEL NEEDLE ... — verify fails on T, and its FAIL lines (or the line
# under one) name every NEEDLE.
refused() {
	_label=$1; shift
	_out=$(verify "$T"); _rc=$?
	_fail_text=$(printf '%s\n' "$_out" | grep -A1 '^  FAIL')
	_st=0
	[ "$_rc" -ne 0 ] || _st=1
	_names=""
	for _needle in "$@"; do
		contains "$_needle" "$_fail_text" || _st=1
		_names="$_names '$_needle'"
	done
	check "TC-756-06 $_label: refused, naming$_names" "$_st" "rc=$_rc; output: $(printf '%s' "$_out" | grep -A1 FAIL | tr '\n' '|')"
	[ -n "$_fail_text" ] && printf '         checker said: %s\n' "$(printf '%s' "$_fail_text" | sed 's/^[[:space:]]*//' | head -2 | tr '\n' ' ')"
}

echo
echo "2. negative controls: the checker refuses each injection (TC-756-06)"
tree; _out=$(verify "$T"); _rc=$?
check "TC-756-06 positive control: an unmodified copy passes" "$(yes_if [ "$_rc" -eq 0 ])" "$(printf '%s' "$_out" | grep -A1 FAIL | tr '\n' '|')"
HCL_REL="$REL_OVERLAY$CONFIG"
ADDR_LINE='  address = "127.0.0.1:8200"'
tree; edit "$T/$HCL_REL" append 'seal "static" {\n  current_key_id = "rasputin-injected"\n}' \
	&& refused 'a seal "static" block' 'seal "static"'
tree; edit "$T/$HCL_REL" "replace:$ADDR_LINE" '  address = "0.0.0.0:8200"' \
	&& refused 'address = "0.0.0.0:8200"' 'address' '0.0.0.0:8200'
tree; edit "$T/$HCL_REL" append 'listener "tcp" {\n  address = "0.0.0.0:8201"\n}' \
	&& refused 'a second listener "tcp" block on 0.0.0.0:8201' 'listener "tcp" {' 'address'
tree; edit "$T/$HCL_REL" 'replace:api_addr = "https://127.0.0.1:8200"' 'api_addr = "https://127.0.0.1:8201"' \
	&& refused 'api_addr on port 8201' 'api_addr' '8201'
tree; edit "$T/$HCL_REL" 'replace:  disable_unauthed_rekey_endpoints = true' '' \
	&& edit "$T/$HCL_REL" 'replace:  disable_unauthed_generate_root_endpoints = true' '' \
	&& edit "$T/$HCL_REL" append 'disable_unauthed_rekey_endpoints = true\ndisable_unauthed_generate_root_endpoints = true' \
	&& refused 'both disable_unauthed_* moved to the top level' 'disable_unauthed_rekey_endpoints' 'disable_unauthed_generate_root_endpoints'
tree; edit "$T/$HCL_REL" 'replace:log_level = "info"' 'log_level = "trace"' \
	&& refused 'log_level = "trace"' 'log_level' 'trace'
tree; edit "$T/$HCL_REL" 'replace:log_level = "info"' 'log_level = "debug"' \
	&& refused 'log_level = "debug"' 'log_level' 'debug'
tree; edit "$T/$HCL_REL" "after:$ADDR_LINE" '  tls_disable = true' \
	&& refused 'tls_disable = true' 'tls_disable'
tree; edit "$T/$HCL_REL" 'replace:  tls_require_and_verify_client_cert = true' '  tls_require_and_verify_client_cert = false' \
	&& refused 'tls_require_and_verify_client_cert = false' 'tls_require_and_verify_client_cert'
tree; edit "$T/$HCL_REL" append 'telemetry {\n  disable_hostname = true\n}' \
	&& refused 'a telemetry block' 'telemetry'
tree; edit "$T/$HCL_REL" 'replace:ui = false' 'ui = true' \
	&& refused 'ui = true' 'ui = false' 'got: true'
tree; edit "$T/$HCL_REL" 'replace:storage "pebbledb" {' 'storage "raft" {' \
	&& refused 'storage "raft"' 'storage "raft"'
tree; edit "$T/$HCL_REL" 'after:disable_clustering = true' 'cluster_addr = "https://127.0.0.1:8201"' \
	&& refused 'a cluster_addr' 'cluster_addr'
tree; edit "$T/$HCL_REL" append 'listener "unix" {\n  address = "/run/openbao.sock"\n}' \
	&& refused 'a second listener, "unix"' 'listener "unix"'
tree; edit "$T/$HCL_REL" 'replace:  tls_client_ca_file = "/run/credentials/openbao.service/store-ca.pem"' \
	'  tls_client_ca_file = "/run/credentials/openbao.service/server.pem"' \
	&& refused 'tls_client_ca_file set to the server.pem credential' 'tls_client_ca_file' 'server.pem'
tree; edit "$T/$HCL_REL" append '# -----BEGIN EC PRIVATE KEY-----\n# not a key, a control\n# -----END EC PRIVATE KEY-----' \
	&& refused 'a PEM block in a comment' '-----BEGIN'
tree; edit "$T/$REL_UNIT" 'after:Environment=GOMEMLIMIT=60MiB' 'Environment=BAO_LOG_LEVEL=trace' \
	&& refused 'Environment=BAO_LOG_LEVEL=trace in the unit' 'BAO_LOG_LEVEL'
tree; edit "$T/$REL_POSTBUILD" "replace:$LINK" '' \
	&& refused 'the post-build link removed' 'multi-user.target.wants/openbao.service' 'got 0'
tree; edit "$T/$REL_POSTBUILD" "after:$LINK" "$LINK" \
	&& refused 'the post-build link duplicated' 'multi-user.target.wants/openbao.service' 'got 2'

# TC-804-13: one injection per audit and self-init check.
# jqedit FILE FILTER — FILE rewritten by jq FILTER; the copy must change.
jqedit() {
	cp "$1" "$1.orig"
	if ! jq "$2" "$1.orig" >"$1" || cmp -s "$1" "$1.orig"; then
		check "the control's jq edit changed $(basename "$1") ($2)" 1
		rm -f "$1.orig"; return 1
	fi
	rm -f "$1.orig"
}
INIT_REL="$REL_OVERLAY$INIT"
# role DATA-FILTER — a jq filter applying DATA-FILTER to the rasputin-api role's data.
api_role() { printf '(.initialize[] | .auth? // empty | .request[] | ."role-rasputin-api"? // empty | .data) |= (%s)' "$1"; }
tree; edit "$T/$HCL_REL" 'replace:    mode = "0600"' '    mode = "0644"' \
	&& refused 'audit mode = "0644"' 'audit mode = 0600' 'got: 0644'
tree; edit "$T/$HCL_REL" 'replace:    log_raw = "false"' '    log_raw = "true"' \
	&& refused 'audit log_raw = "true"' 'log_raw = false'
tree; edit "$T/$HCL_REL" 'replace:    hmac_accessor = "true"' '    hmac_accessor = "false"' \
	&& refused 'audit hmac_accessor = "false"' 'hmac_accessor = true'
tree; edit "$T/$HCL_REL" 'replace:    file_path = "/var/lib/rasputin/openbao-audit/audit.log"' '    file_path = "/var/lib/rasputin/audit.log"' \
	&& refused 'audit file_path outside the ReadWritePaths' 'audit file_path (/var/lib/rasputin/audit.log)'
tree; edit "$T/$HCL_REL" 'after:    hmac_accessor = "true"' '    prefix = "x"' \
	&& refused 'an extra audit option' 'file_path, mode, log_raw and hmac_accessor' 'prefix'
tree; edit "$T/$HCL_REL" append 'initialize "policies" {\n  x = "y"\n}' \
	&& refused 'an initialize stanza in openbao.hcl' 'no initialize stanza' 'initialize'
tree; jqedit "$T/$INIT_REL" '.initialize += [{"audit": {"request": [{"audit-file": {"operation": "update", "path": "sys/audit/file", "data": {"type": "file"}}}]}}]' \
	&& refused 'a sys/audit request in init.json' 'no request touches sys/audit' 'sys/audit/file'
tree; jqedit "$T/$INIT_REL" '.initialize[0].policies.request[0]."policy-rasputin-api".allow_failure = true' \
	&& refused 'allow_failure on a request' 'no allow_failure anywhere' 'found 1'
tree; jqedit "$T/$INIT_REL" '.initialize[0].policies.token = "root"' \
	&& refused 'a token field' 'no token field anywhere' 'found 1'
tree; jqedit "$T/$INIT_REL" '.initialize[0].policies.request[0]."policy-rasputin-api".data.policy.eval_source = "env"' \
	&& refused 'an env source' 'no env or other non-file source' 'env'
tree; jqedit "$T/$INIT_REL" '.initialize[1].secrets.request += [{"kv-extra": {"operation": "update", "path": "sys/mounts/extra", "data": {"type": "kv"}}}]' \
	&& refused 'an extra mount request' "init.json's requests are exactly" 'sys/mounts/extra'
tree; jqedit "$T/$INIT_REL" "$(api_role '.allowed_common_names = ["*"]')" \
	&& refused 'the api role admitting any CommonName' 'role rasputin-api: CN rasputin-api only' '"allowed_common_names":["*"]'
tree; jqedit "$T/$INIT_REL" "$(api_role '.token_no_default_policy = false')" \
	&& refused 'the api role keeping the default policy' 'role rasputin-api' '"token_no_default_policy":false'
tree; jqedit "$T/$INIT_REL" "$(api_role '.certificate.path = "/run/credentials/openbao.service/server.pem"')" \
	&& refused 'the api role trusting the server leaf, not the store CA' 'role rasputin-api' 'server.pem'
tree; jqedit "$T/$INIT_REL" "$(api_role '.token_policies = ["rasputin-api", "rasputin-seal-rotate"]')" \
	&& refused 'the api role also granting the rotation policy' 'rasputin-seal-rotate is bound only by its own role' 'auth/cert/certs/rasputin-api'
# TC-805-24: the provisioner's role widened, the bindable policy bound at init,
# and an entry in the shipped provision.tsv.
prov_role() { printf '(.initialize[] | .auth? // empty | .request[] | ."role-rasputin-provisioner"? // empty | .data) |= (%s)' "$1"; }
tree; jqedit "$T/$INIT_REL" "$(prov_role '.token_policies = ["rasputin-provisioner", "rasputin-api"]')" \
	&& refused 'the provisioner role also granting the api policy' 'role rasputin-provisioner' '"token_policies":["rasputin-provisioner","rasputin-api"]'
tree; jqedit "$T/$INIT_REL" "$(prov_role '.token_ttl = "24h"')" \
	&& refused 'the provisioner role with a 24h ttl' 'role rasputin-provisioner' '"token_ttl":"24h"'
tree; jqedit "$T/$INIT_REL" "$(api_role '.token_policies = ["rasputin-api", "rasputin-bindable"]')" \
	&& refused 'the api role binding rasputin-bindable' 'rasputin-bindable is bound by no init.json role' 'auth/cert/certs/rasputin-api'
tree; edit "$T/$REL_OVERLAY/etc/rasputin/openbao/provision.tsv" append 'mount	rasputin-rel-x' \
	&& refused 'an entry in the shipped provision.tsv' 'the shipped provision.tsv holds no entry' 'rasputin-rel-x'
tree; jqedit "$T/$INIT_REL" '.initialize[0].policies.request[1]."policy-rasputin-seal-rotate".data.policy.path = "/tmp/rasputin-seal-rotate.hcl"' \
	&& refused 'a policy file source outside openbao-policy/' 'every file source is under /usr/share/rasputin/openbao-policy/' '/tmp/rasputin-seal-rotate.hcl'

# --- the libraries, table-tested (TC-756-07) ----------------------------------------
echo
echo "3. bao_listeners and listening_sockets (TC-756-07)"
FX="$SCRATCH/fixture"
# Inodes: A 1001, B 1002, C 1003, D 1004, E 1005.
cat >"$FX" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:2008 00000000:0000 0A 00000000:00000000 00:00000000 00000000   990        0 1001 1 0000000000000000 100 0 0 10 0
   1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000   990        0 1002 1 0000000000000000 100 0 0 10 0
   2: 0100007F:2008 0100007F:D431 01 00000000:00000000 00:00000000 00000000   990        0 1001 1 0000000000000000 20 4 30 10 -1
   3: 0100007F:2009 00000000:0000 0A 00000000:00000000 00:00000000 00000000   990        0 1003 1 0000000000000000 100 0 0 10 0
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:2008 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   990        0 1004 1 0000000000000000 100 0 0 10 0
   1: 00000000000000000000000001000000:2008 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000   990        0 1005 1 0000000000000000 100 0 0 10 0
total 0
lr-x------ 1 990 990 64 Oct 11 10:00 0 -> /dev/null
lrwx------ 1 990 990 64 Oct 11 10:00 7 -> socket:[1001]
lrwx------ 1 990 990 64 Oct 11 10:00 8 -> socket:[1002]
lrwx------ 1 990 990 64 Oct 11 10:00 9 -> socket:[1004]
lrwx------ 1 990 990 64 Oct 11 10:00 10 -> socket:[1005]
EOF
got=$(bao_listeners <"$FX")
want='127.0.0.1:8200
0.0.0.0:8080
[::]:8200
[::1]:8200'
check "TC-756-07 bao_listeners prints exactly 127.0.0.1:8200, 0.0.0.0:8080, [::]:8200 and [::1]:8200, once each: the ESTABLISHED row and inode C (no fd) are left out" \
	"$(yes_if [ "$got" = "$want" ])" "got: $(printf '%s' "$got" | tr '\n' '|')"
got=$(listening_sockets <"$FX")
check "TC-756-07 listening_sockets prints every LISTEN row, fd or not (127.0.0.1:8201 too)" \
	"$(yes_if [ "$got" = "127.0.0.1:8200
0.0.0.0:8080
127.0.0.1:8201
[::]:8200
[::1]:8200" ])" "got: $(printf '%s' "$got" | tr '\n' '|')"
got=$(bao_listeners </dev/null); rc=$?
st=1; [ -z "$got" ] && [ "$rc" -eq 0 ] && st=0
check "TC-756-07 empty input prints nothing and exits 0" "$st" "rc=$rc got: $got"

echo
echo "4. hcl_get and hcl_keys (TC-756-07, F-756-09)"
H1="$SCRATCH/h1.hcl" H2="$SCRATCH/h2.hcl" H3="$SCRATCH/h3.hcl" H4="$SCRATCH/h4.hcl"
cat >"$H1" <<'EOF'
# a fixture
address = "top-level"
ui = false # a trailing comment
listener "tcp" {
  # address = "commented-out"
  address = "127.0.0.1:8200"  // a trailing comment
  tls_disable = true
}
storage "pebbledb" {
  path = "/x"
}
EOF
printf 'listener "tcp" {\n  address = "a"\n  address = "b"\n}\n' >"$H2"
printf 'listener "tcp" {\n  address = "a"\n}\nlistener "tcp" {\n  address = "b"\n}\n' >"$H3"
printf 'listener "tcp" { address = "a" }\n' >"$H4"
# row LABEL WANT_RC WANT_OUT NEEDLE CMD... — CMD exits WANT_RC (0, or "nz" for
# non-zero), prints WANT_OUT on stdout, and its stderr names NEEDLE.
row() {
	_l=$1 _wrc=$2 _wout=$3 _wneedle=$4; shift 4
	_o=$("$@" 2>"$SCRATCH/row.err"); _r=$?
	_e=$(cat "$SCRATCH/row.err")
	_st=0
	if [ "$_wrc" = nz ]; then [ "$_r" -ne 0 ] || _st=1; else [ "$_r" -eq "$_wrc" ] || _st=1; fi
	[ "$_o" = "$_wout" ] || _st=1
	[ -z "$_wneedle" ] || contains "$_wneedle" "$_e" || _st=1
	check "TC-756-07 $_l" "$_st" "rc=$_r stdout: $(printf '%s' "$_o" | tr '\n' '|') stderr: $_e"
}
row "hcl_get reads the in-block value without quotes, ignoring the top-level key and a commented-out one" \
	0 127.0.0.1:8200 '' hcl_get "$H1" 'listener "tcp"' address
row "hcl_get with an empty block reads only the top level" 0 top-level '' hcl_get "$H1" '' address
row "hcl_get reads a bare value with a trailing comment" 0 false '' hcl_get "$H1" '' ui
row "hcl_get refuses a missing key, naming it" nz '' 'has no cluster_addr' hcl_get "$H1" '' cluster_addr
row "hcl_get refuses a key twice in one block, naming it" nz '' 'has address 2 times' hcl_get "$H2" 'listener "tcp"' address
row "hcl_get refuses a key in two blocks of the same name: one scope, so twice" nz '' 'has address 2 times' hcl_get "$H3" 'listener "tcp"' address
row "hcl_get refuses a missing file, naming it" nz '' "$SCRATCH/none.hcl" hcl_get "$SCRATCH/none.hcl" '' address
row "hcl_get refuses a line it cannot read rather than guess" nz '' "Could not read $H4. Line 1 is not a key, a block header or a closing brace" hcl_get "$H4" 'listener "tcp"' address
# Every other refusal in the reader (F-756-11): each fixture is readable up to
# line 3, so the line number in the sentence is the refusing line's own.
# refusal LABEL N LINE WHY — the sentence names the file, line 3 and WHY.
refusal() {
	_rl=$1 _rn=$2 _rtext=$3 _rwhy=$4
	printf 'ui = false\nlistener "tcp" {\n%s\n}\n' "$_rtext" >"$SCRATCH/r$_rn.hcl"
	row "hcl_get refuses $_rl, naming the file and line 3" nz '' "Could not read $SCRATCH/r$_rn.hcl. Line 3 $_rwhy" \
		hcl_get "$SCRATCH/r$_rn.hcl" '' ui
}
refusal "a /* comment" 1 '  /* a comment */' 'opens a /* comment'
refusal "a block header it cannot read" 2 '  1nner {' 'is not a block header'
refusal "a string with no closing quote" 3 '  address = "127.0.0.1:8200' 'has a string with no closing quote'
refusal "a value it cannot parse" 4 '  ports = [8200, 8201]' 'has a value this reader does not parse'
refusal "text after a value" 5 '  address = "127.0.0.1:8200" extra' 'has text after its value'
printf 'ui = false\nlistener "tcp" {\n}\n}\n' >"$SCRATCH/r6.hcl"
row "hcl_get refuses a } with no open block, naming the file and line 4" nz '' "Could not read $SCRATCH/r6.hcl. Line 4 closes a block that was never opened" \
	hcl_get "$SCRATCH/r6.hcl" '' ui
printf 'ui = false\nlistener "tcp" {\n  address = "a"\n' >"$SCRATCH/r7.hcl"
row "hcl_get refuses a file that ends inside a block, naming the file and the block's line 2" nz '' \
	"Could not read $SCRATCH/r7.hcl. Line 2 opens a block that the file never closes" hcl_get "$SCRATCH/r7.hcl" '' ui
# A nested block is a scope of its own, "OUTER / INNER" (F-756-11).
printf 'outer "x" {\n  k = 1\n  inner {\n    j = "v"\n  }\n}\n' >"$SCRATCH/nest.hcl"
row "hcl_keys lists a nested block in its parent as a header with { after it" 0 'k
inner {' '' hcl_keys "$SCRATCH/nest.hcl" 'outer "x"'
row "hcl_get reads a nested block's key through 'OUTER / INNER'" 0 v '' hcl_get "$SCRATCH/nest.hcl" 'outer "x" / inner' j
row "hcl_get does not see a nested block's key in the parent" nz '' 'has no j in the outer "x" block' \
	hcl_get "$SCRATCH/nest.hcl" 'outer "x"' j
row "hcl_keys lists the top level's keys and headers in file order, comments excluded" 0 'address
ui
listener "tcp" {
storage "pebbledb" {' '' hcl_keys "$H1" ''
row "hcl_keys lists a block's keys, the commented-out key excluded" 0 'address
tls_disable' '' hcl_keys "$H1" 'listener "tcp"'
row "hcl_keys treats two blocks of the same name as one scope: the key is listed twice" 0 'address
address' '' hcl_keys "$H3" 'listener "tcp"'
row "hcl_keys refuses a block that is not there, naming it" nz '' 'no seal "static" block' hcl_keys "$H1" 'seal "static"'
row "hcl_keys refuses a missing file, naming it" nz '' "$SCRATCH/none.hcl" hcl_keys "$SCRATCH/none.hcl" ''

# --- the test fails closed (TC-756-08) ------------------------------------------------
echo
echo "5. the test fails closed (TC-756-08)"
SH_BIN=$(command -v sh)
# full_root — a scratch root with this script, its libraries and every input.
full_root() {
	tree
	mkdir -p "$T/test/lib"
	cp "$0" "$T/test/store-config-test.sh"
	for f in checks.sh hcl-keys.sh unit-directives.sh mk-var.sh listen-sockets.sh; do cp "$LIB/$f" "$T/test/lib/"; done
}
for gone in "$REL_OVERLAY$CONFIG" "$REL_OVERLAY$INIT" "$REL_UNIT" "$REL_POSTBUILD" test/lib/hcl-keys.sh; do
	full_root
	rm -f "${T:?}/$gone"
	out=$("$SH_BIN" "$T/test/store-config-test.sh" "$T" 2>&1); rc=$?
	check "TC-756-08 with no $(basename "$gone") the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
	st=1
	[ "$(printf '%s\n' "$out" | grep -c '')" -eq 1 ] && contains "$gone" "$out" \
		&& contains 'FAILED: ' "$out" && ! contains passed "$out" && st=0
	check "TC-756-08 with no $(basename "$gone") the one line it prints is a FAILED: sentence naming the file, and nothing says passed" \
		"$st" "$out"
	printf '         it said: %s\n' "$out"
done

echo
if [ "$fails" -ne 0 ]; then echo "store-config-test: $fails check(s) FAILED"; exit 1; fi
echo "store-config-test: all checks passed"
