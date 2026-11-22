#!/bin/sh
#
# Table tests for usr/lib/rasputin/node-id/node-id.sh — the DNS-label helpers
# rasputin-firstboot.sh and rasputin-hostname.sh share.
#
# Why. The node id is the node's mDNS hostname and the NATS username the agent
# presents to the bus, and the control plane accepts only a DNS label (1-63 of
# a-z 0-9 -, no leading or trailing -). An id that breaks the rule is not caught
# by the build or the syntax check: the node boots and simply never joins. So
# the rule is pinned here, case by case. geekdojo/geekdojo-brain#441.
#
# Shells. The image's /bin/sh is busybox ash (Buildroot's default; the
# defconfigs select no other). Every case runs under each shell
# in TEST_SHELLS (default: whichever of sh, dash, bash and `busybox sh` are
# installed), so a construct one shell reads differently fails here rather than
# at boot. REQUIRE_BUSYBOX=1 (CI sets it; the hosted runner ships busybox)
# turns a missing busybox into a failure, so the target shell cannot silently
# drop out of the run.
#
# Run:  sh test/node-id-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LIBDIR="$ROOT/board/rasputin/common/rootfs-overlay/usr/lib/rasputin"
LIB="$LIBDIR/node-id/node-id.sh"
HOSTNAME_SCRIPT="$LIBDIR/hostname/rasputin-hostname.sh"
[ -f "$LIB" ] || { echo "missing: $LIB" >&2; exit 2; }
[ -f "$HOSTNAME_SCRIPT" ] || { echo "missing: $HOSTNAME_SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi

pass=0
fail=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# run SHELL FUNCTION ARG — print the function's output, then "|rc=<status>".
# The marker keeps an empty output distinguishable from a missing one.
run() {
	_sh=$1; shift
	case "$_sh" in
		busybox_sh) set -- busybox sh -c '. "$0"; "$@"; printf "|rc=%s" "$?"' "$LIB" "$@" ;;
		*)          set -- "$_sh" -c '. "$0"; "$@"; printf "|rc=%s" "$?"' "$LIB" "$@" ;;
	esac
	"$@" 2>&1
}

# expect SHELL LABEL WANT FUNCTION ARG
expect() {
	_sh=$1 _label=$2 _want=$3; shift 3
	_got=$(run "$_sh" "$@")
	if [ "$_got" = "$_want" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n       want: %s\n       got:  %s\n' "$_sh" "$_label" "$_want" "$_got" >&2
	fi
}

first63=abcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabcdefghijabc
tab=$(printf '\t')
cr=$(printf '\r')
nl='
'
# Cluster ids either side of the 59-character limit (geekdojo/geekdojo-brain#996).
id59=${first63%????}
id60=${first63%???}
[ "${#id59}" -eq 59 ] && [ "${#id60}" -eq 60 ] || { echo "bad test vectors" >&2; exit 2; }

# The three refusal sentences of rasputin_cluster_id_check, written out here so
# the test pins the exact text rather than re-deriving it from the helper.
s1() { printf "The cluster id '%s' is %s characters, and a cluster id allows at most 59 so that its sign-in name, sso-<cluster id>.local, fits in one DNS label." "$1" "$2"; }
s2() { printf "The cluster id '%s' starts with sso-, which is reserved for sign-in names: every cluster signs in at sso-<cluster id>.local, so this one would publish another cluster's sign-in name." "$1"; }
s3() { printf "The cluster id '%s' is not a DNS label: it may hold only a-z, 0-9 and -, and must not start or end with -." "$1"; }

# hostname SHELL NODE_ENV_FILE — run the real rasputin-hostname.sh through its
# RASPUTIN_HOSTNAME_* overrides against a scratch kernel-hostname file and kmsg.
# Sets HN_OUT (stdout+stderr) and HN_NAME (what it wrote as the hostname).
hostname_run() {
	_hd=$(mktemp -d "$TMP/hn.XXXXXX")
	_ne=$2
	printf 'rasputin-node' > "$_hd/hostname"
	case "$1" in
		busybox_sh) set -- busybox sh "$HOSTNAME_SCRIPT" ;;
		*)          set -- "$1" "$HOSTNAME_SCRIPT" ;;
	esac
	HN_OUT=$(RASPUTIN_HOSTNAME_NODE_ENV="$_ne" \
		RASPUTIN_HOSTNAME_LIBDIR="$LIBDIR" \
		RASPUTIN_HOSTNAME_KERNEL="$_hd/hostname" \
		RASPUTIN_HOSTNAME_KMSG="$_hd/kmsg" \
		"$@" 2>&1)
	HN_NAME=$(cat "$_hd/hostname")
}

has() { printf '%s\n' "$1" | grep -qF -- "$2"; }
not_has() { if has "$1" "$2"; then return 1; else return 0; fi; }

# check LABEL CONDITION... — count a pass when CONDITION succeeds.
check() {
	_label=$1; shift
	if "$@"; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$sh" "$_label" >&2
	fi
}

for sh in $TEST_SHELLS; do
	echo "== $sh"

	# ---- rasputin_label_canon: operator ids (lowercase + trim only) ------
	f=rasputin_label_canon
	expect "$sh" "canon lowercases"      "kitchen-pi|rc=0"   $f "Kitchen-Pi"
	expect "$sh" "canon trims"           "fw-1|rc=0"         $f "  fw-1${tab}"
	expect "$sh" "canon strips CRLF"     "fw-1|rc=0"         $f "fw-1${cr}"
	expect "$sh" "canon trims newlines"  "fw-1|rc=0"         $f "${nl}fw-1${nl}"
	expect "$sh" "canon keeps inner"     "abc 123|rc=0"      $f " ABC 123 "
	expect "$sh" "canon keeps dot"       "a.b|rc=0"          $f "a.b"
	expect "$sh" "canon blank"           "|rc=0"             $f "   "
	expect "$sh" "canon keeps wildcard"  "*|rc=0"            $f "*"

	# ---- rasputin_label_valid ---------------------------------------------
	f=rasputin_label_valid
	expect "$sh" "valid simple"          "|rc=0"  $f "kitchen-pi"
	expect "$sh" "valid one char"        "|rc=0"  $f "a"
	expect "$sh" "valid digits"          "|rc=0"  $f "0123"
	expect "$sh" "valid node-hex shape"  "|rc=0"  $f "node-9bbaa24a"
	expect "$sh" "valid 63"              "|rc=0"  $f "$first63"
	expect "$sh" "invalid 64"            "|rc=1"  $f "${first63}d"
	expect "$sh" "invalid empty"         "|rc=1"  $f ""
	expect "$sh" "invalid uppercase"     "|rc=1"  $f "Kitchen-Pi"
	expect "$sh" "invalid leading -"     "|rc=1"  $f "-a"
	expect "$sh" "invalid trailing -"    "|rc=1"  $f "a-"
	expect "$sh" "invalid lone -"        "|rc=1"  $f "-"
	expect "$sh" "invalid wildcard"      "|rc=1"  $f "*"
	expect "$sh" "invalid gt"            "|rc=1"  $f ">"
	expect "$sh" "invalid dot"           "|rc=1"  $f "a.b"
	expect "$sh" "invalid space"         "|rc=1"  $f "a b"
	expect "$sh" "invalid underscore"    "|rc=1"  $f "a_b"
	expect "$sh" "invalid tab"           "|rc=1"  $f "a${tab}b"
	expect "$sh" "invalid newline"       "|rc=1"  $f "a${nl}b"
	expect "$sh" "invalid non-ASCII"     "|rc=1"  $f "café"
	expect "$sh" "invalid bracket"       "|rc=1"  $f "a[b]"

	# ---- rasputin_cluster_id_check (TC-996-05) -----------------------------
	# A new cluster's id: a DNS label of at most 59 characters that does not
	# start with sso- (geekdojo/geekdojo-brain#996). Checked in order: length
	# (S1), then the DNS-label rule (S3), then the prefix (S2).
	f=rasputin_cluster_id_check
	expect "$sh" "cluster id bench"          "|rc=0"  $f "bench"
	expect "$sh" "cluster id rasputin"       "|rc=0"  $f "rasputin"
	expect "$sh" "cluster id sso"            "|rc=0"  $f "sso"
	expect "$sh" "cluster id sso1"           "|rc=0"  $f "sso1"
	expect "$sh" "cluster id 59 chars"       "|rc=0"  $f "$id59"
	expect "$sh" "cluster id sso-x (S2)"     "$(s2 sso-x)${nl}|rc=1"      $f "sso-x"
	expect "$sh" "cluster id 60 chars (S1)"  "$(s1 "$id60" 60)${nl}|rc=1" $f "$id60"
	expect "$sh" "cluster id a_b (S3)"       "$(s3 a_b)${nl}|rc=1"        $f "a_b"
	expect "$sh" "cluster id home.lab (S3)"  "$(s3 home.lab)${nl}|rc=1"   $f "home.lab"
	expect "$sh" "cluster id sso- (S3)"      "$(s3 sso-)${nl}|rc=1"       $f "sso-"
	# The rule hostname.sh relies on is unchanged: both are still DNS labels.
	expect "$sh" "label_valid still takes sso-x"     "|rc=0"  rasputin_label_valid "sso-x"
	expect "$sh" "label_valid still takes 60 chars"  "|rc=0"  rasputin_label_valid "$id60"

	# ---- upgrade path: rasputin-hostname.sh (TC-996-09) --------------------
	# A controlplane node.env written by a firstboot that predates the cluster
	# id rule keeps its hostname: rasputin-hostname.sh still checks only that
	# the id is a DNS label, and does not fall back to "rasputin".
	for cid in sso-x "$id60"; do
		ne="$TMP/node.env.$$"
		printf "RASPUTIN_NODE_ROLE='controlplane'\nRASPUTIN_NODE_ID='cp1'\nRASPUTIN_CLUSTER_ID='%s'\n" "$cid" > "$ne"
		hostname_run "$sh" "$ne"
		check "hostname keeps pre-rule cluster id '$cid'" test "$HN_NAME" = "$cid"
		check "hostname: no WARNING for '$cid'" not_has "$HN_OUT" "WARNING"
		check "hostname: no fallback to rasputin for '$cid'" not_has "$HN_OUT" "falling back to 'rasputin'"
		check "hostname: logs the name set for '$cid'" has "$HN_OUT" "transient hostname set to $cid (role=controlplane)"
	done
done

echo
if [ -z "$TEST_SHELLS" ]; then
	echo "node-id: no shell found to test under" >&2
	exit 1
fi
case " $TEST_SHELLS " in
	*" busybox_sh "*) ;;
	*)
		if [ "${REQUIRE_BUSYBOX:-0}" = "1" ]; then
			echo "node-id: REQUIRE_BUSYBOX=1 but busybox is not installed — the target shell was not tested" >&2
			exit 1
		fi ;;
esac
if [ "$fail" -eq 0 ]; then
	echo "node-id: $pass check(s) passed"
	exit 0
fi
echo "node-id: $fail check(s) FAILED, $pass passed" >&2
exit 1
