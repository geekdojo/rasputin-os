#!/bin/sh
#
# Functional tests for rasputin-firstboot.sh's seed handling, starting with the
# bus TLS values (geekdojo/geekdojo-brain#448): RASPUTIN_BUS_PIN in every seed,
# RASPUTIN_BUS_KEY in the controlplane seed only. Then the join token, which
# goes into its own 0600 file that node.env merely NAMES
# (geekdojo/geekdojo-brain#537).
#
# Why. What firstboot does with a seed is invisible when wrong, and it only
# runs once. A pin that never reaches node.env is a node that silently stays on
# plaintext. A bus key written to the wrong place, overwritten, left on the
# seed FAT, or copied into node.env is the fleet's private key at rest where it
# should not be — or a controlplane whose api generates a DIFFERENT key than the
# one every node in its matched set pins, which strands them all. None of that
# is caught by the syntax check or the image build, and all of it is cheap to
# pin here.
#
# How. The real script runs against a scratch directory: its RASPUTIN_FIRSTBOOT_*
# overrides point the persistent partition, the seed mount, /proc/cmdline and
# /dev/kmsg into it and swap mount for a recording stub, and stubs on PATH stand
# in for systemctl and sync.
# No root, no partitions, no systemd.
#
# Keys. The bus key and pin are generated per run with openssl, and the pin with
# the exact recipe the contract gives operators ("Checking a pin by hand" in
# rasputin-control-plane docs/bus-tls-contract.md), so a key/pin pair that does
# not match is impossible here. No key is committed. Where openssl is missing
# (a busybox container), pass pre-generated values in TEST_KEY_P256,
# TEST_KEY_ED25519, TEST_KEY_RSA and TEST_PIN (the P-256 key's pin); the run
# fails rather than skip when neither is available.
#
# Shells. Every case runs under each shell in TEST_SHELLS (default: whichever
# of sh, dash, bash and `busybox sh` are installed). REQUIRE_BUSYBOX=1 (CI sets
# it) fails the run when busybox is missing, since busybox ash is the image's
# /bin/sh.
#
# Run:  sh test/firstboot-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SCRIPT="$OVERLAY/usr/lib/rasputin/firstboot/rasputin-firstboot.sh"
LIBDIR="$OVERLAY/usr/lib/rasputin"
API_UNIT="$OVERLAY/etc/systemd/system/rasputin-api.service"
AGENT_UNIT="$OVERLAY/etc/systemd/system/rasputin-agent.service"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

if [ -z "${TEST_SHELLS:-}" ]; then
	TEST_SHELLS=""
	for s in sh dash bash; do
		command -v "$s" >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS $s"
	done
	command -v busybox >/dev/null 2>&1 && TEST_SHELLS="$TEST_SHELLS busybox_sh"
fi
if [ "${REQUIRE_BUSYBOX:-0}" = "1" ] && ! command -v busybox >/dev/null 2>&1; then
	echo "FAIL: REQUIRE_BUSYBOX=1 but busybox is not installed" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- keys ---------------------------------------------------------------------
# gen_key ALGORITHM-ARGS... — print a fresh key as one line of base64 PKCS#8 DER,
# the form RASPUTIN_BUS_KEY carries.
gen_key() {
	openssl genpkey "$@" 2>/dev/null \
		| openssl pkcs8 -topk8 -nocrypt -outform DER 2>/dev/null \
		| openssl base64 -A
}
# pin_of KEYLINE — the contract's own recipe.
pin_of() {
	printf '%s\n' "$1" | openssl base64 -d -A \
		| openssl pkey -inform der -pubout -outform der 2>/dev/null \
		| openssl dgst -sha256 -binary | openssl base64 -A
}
HAVE_OPENSSL=0
command -v openssl >/dev/null 2>&1 && HAVE_OPENSSL=1
if [ -z "${TEST_KEY_P256:-}" ]; then
	[ "$HAVE_OPENSSL" = 1 ] || { echo "FAIL: no openssl and no TEST_KEY_* values to test with" >&2; exit 1; }
	TEST_KEY_P256=$(gen_key -algorithm EC -pkeyopt ec_paramgen_curve:P-256)
	TEST_KEY_ED25519=$(gen_key -algorithm ED25519)
	TEST_KEY_RSA=$(gen_key -algorithm RSA -pkeyopt rsa_keygen_bits:2048)
	TEST_PIN="sha256/$(pin_of "$TEST_KEY_P256")"
fi
: "${TEST_KEY_ED25519:?}" "${TEST_KEY_RSA:?}" "${TEST_PIN:?}"
KEY=$TEST_KEY_P256
PIN=$TEST_PIN
# A second key, for "an existing bus.key is never replaced".
OTHER_KEY=$TEST_KEY_ED25519

# The vectors themselves must be what the cases assume, or every case below
# tests the wrong thing.
[ "${#PIN}" -eq 51 ] || { echo "FAIL: test pin is not 51 characters: $PIN" >&2; exit 1; }
case "$KEY" in MIG*) ;; *) echo "FAIL: P-256 test key is not PKCS#8 DER (30 81 ..)" >&2; exit 1 ;; esac
case "$TEST_KEY_ED25519" in MC4*) ;; *) echo "FAIL: Ed25519 test key is not PKCS#8 DER (30 2e ..)" >&2; exit 1 ;; esac
case "$TEST_KEY_RSA" in MII*) ;; *) echo "FAIL: RSA test key is not PKCS#8 DER (30 82 ..)" >&2; exit 1 ;; esac

# --- harness ------------------------------------------------------------------
pass=0
fail=0
SH=""

ok() {
	if [ "$2" = 0 ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		printf '  FAIL [%s] %s\n' "$SH" "$1" >&2
		[ -n "${3:-}" ] && printf '       %s\n' "$3" | head -20 >&2
	fi
	return 0
}
yes_if() { if "$@"; then echo 0; else echo 1; fi; }
not() { if "$@"; then return 1; else return 0; fi; }

# setup — a fresh world: persistent dir, seed mount, stubs.
setup() {
	W=$(mktemp -d "$TMP/w.XXXXXX")
	P="$W/persist"; M="$W/seed"; SEED="$M/rasputin-seed.env"; BIN="$W/bin"
	mkdir -p "$P" "$M" "$BIN"
	: > "$W/cmdline"; : > "$W/kmsg"; : > "$W/mount.calls"
	cat > "$BIN/mount" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_MOUNT_CALLS"
exit "${STUB_MOUNT_RC:-0}"
STUB
	# The agent the seed is checked through. Absent by default — most cases
	# are about firstboot, not about the check — so they take the documented
	# fallback; agent_stub() installs one when a case is about it.
	AGENT="$BIN/rasputin-agent-absent"
	printf '#!/bin/sh\nexit 0\n' > "$BIN/systemctl"
	printf '#!/bin/sh\nexit 0\n' > "$BIN/sync"
	chmod +x "$BIN/mount" "$BIN/systemctl" "$BIN/sync"
	STUB_MOUNT_RC=0
}

# seed LINE... — write the seed file, one argument per line.
seed() { printf '%s\n' "$@" > "$SEED"; }

# agent_stub BODY — install a fake `rasputin-agent` whose `seed check` behaves
# as BODY says. The real one is a Go binary built from another repo; what
# firstboot depends on is the contract (exit 0 with a normalized seed on
# stdout, 1 with the reason on stderr and nothing on stdout, 2 for a build
# that has never heard of the subcommand), and that is what this drives.
agent_stub() {
	AGENT="$BIN/rasputin-agent"
	{
		printf '#!/bin/sh\n'
		printf 'if [ "$1" != seed ] || [ "$2" != check ]; then\n'
		printf '  echo "rasputin-agent: unknown command \\"$1\\"" >&2\n'
		printf '  exit 2\n'
		printf 'fi\n'
		printf 'shift 2\n'
		printf '%s\n' "$1"
	} > "$AGENT"
	chmod +x "$AGENT"
}

# fb — run firstboot; sets OUT (stdout+stderr) and RC.
fb() {
	case "$SH" in
		busybox_sh) set -- busybox sh "$SCRIPT" ;;
		*)          set -- "$SH" "$SCRIPT" ;;
	esac
	OUT=$(PATH="$BIN:$PATH" STUB_MOUNT_CALLS="$W/mount.calls" STUB_MOUNT_RC="$STUB_MOUNT_RC" \
		RASPUTIN_FIRSTBOOT_PERSIST="$P" \
		RASPUTIN_FIRSTBOOT_SEED_MNT="$M" \
		RASPUTIN_FIRSTBOOT_LIBDIR="$LIBDIR" \
		RASPUTIN_FIRSTBOOT_CMDLINE="$W/cmdline" \
		RASPUTIN_FIRSTBOOT_KMSG="$W/kmsg" \
		RASPUTIN_FIRSTBOOT_MOUNT="$BIN/mount" \
		RASPUTIN_FIRSTBOOT_AGENT="$AGENT" \
		"$@" 2>&1)
	RC=$?
}

perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }
has_line() { grep -qxF -- "$2" "$1" 2>/dev/null; }
contains() { grep -qF -- "$2" "$1" 2>/dev/null; }
out_has() { printf '%s\n' "$OUT" | grep -qF -- "$1"; }
provisioned() { [ -f "$P/.provisioned" ]; }

compute_seed() {
	seed "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" "RASPUTIN_CLUSTER_ID=bench" \
		"RASPUTIN_NATS_URL=nats://bench.local:4222" "RASPUTIN_CP_JOIN_TOKEN=tok-w1" "$@"
}
cp_seed() {
	seed "RASPUTIN_NODE_ROLE=controlplane" "RASPUTIN_NODE_ID=cp1" "RASPUTIN_CLUSTER_ID=bench" \
		"RASPUTIN_NATS_URL=nats://127.0.0.1:4222" "RASPUTIN_BUS_AUTH=enforce" "$@"
}

# --- cases --------------------------------------------------------------------
cases() {
	# 1. A seed with no bus lines: no pin in node.env, and the join token is
	#    still scrubbed. The token itself goes to bus/join.token, and node.env
	#    NAMES that file rather than carrying the token
	#    (geekdojo/geekdojo-brain#537).
	setup; compute_seed; fb
	ok "no bus lines: provisions" "$RC" "$OUT"
	ok "no bus lines: no RASPUTIN_BUS_PIN in node.env" "$(yes_if not contains "$P/node.env" RASPUTIN_BUS_PIN)" "$(cat "$P/node.env")"
	ok "no bus lines: the bus dir holds only the join token" "$(yes_if test "$(ls -A "$P/bus")" = "join.token")" "$(ls -A "$P/bus" 2>&1)"
	ok "no bus lines: compute node.env names the join token file" "$(yes_if has_line "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN_FILE='$P/bus/join.token'")" "$(cat "$P/node.env")"
	ok "no bus lines: join token still scrubbed" "$(yes_if has_line "$SEED" "RASPUTIN_CP_JOIN_TOKEN=")" "$(cat "$SEED")"

	# 2. Compute: the pin goes into node.env verbatim and stays in the seed.
	setup; compute_seed "RASPUTIN_BUS_PIN=$PIN"; fb
	ok "compute pin: provisions" "$RC" "$OUT"
	ok "compute pin: node.env carries it" "$(yes_if has_line "$P/node.env" "RASPUTIN_BUS_PIN='$PIN'")" "$(cat "$P/node.env")"
	ok "compute pin: stays in the seed (public)" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_PIN=$PIN")" "$(cat "$SEED")"
	ok "compute pin: the bus dir holds only the join token" "$(yes_if test "$(ls -A "$P/bus")" = "join.token")" "$(ls -A "$P/bus" 2>&1)"

	# 3. Controlplane with key + pin: the full contract.
	setup; cp_seed "RASPUTIN_BUS_PIN=$PIN" "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "cp key: provisions" "$RC" "$OUT"
	printf '%s\n' "$KEY" > "$W/want.key"
	ok "cp key: bus.key is the value verbatim plus one newline" "$(yes_if cmp -s "$W/want.key" "$P/bus/bus.key")" "$(cat "$P/bus/bus.key" 2>&1)"
	ok "cp key: bus.key is 0600" "$(yes_if test "$(perms "$P/bus/bus.key")" = "-rw-------")" "$(perms "$P/bus/bus.key")"
	ok "cp key: bus dir is 0700" "$(yes_if test "$(perms "$P/bus")" = "drwx------")" "$(perms "$P/bus")"
	ok "cp key: no temp file left beside it" "$(yes_if test "$(ls -A "$P/bus")" = "bus.key")" "$(ls -A "$P/bus")"
	ok "cp key: node.env names the agent token file the api mints" "$(yes_if has_line "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN_FILE='$P/bus/agent.token'")" "$(cat "$P/node.env")"
	ok "cp key: node.env carries no join token of its own" "$(yes_if not contains "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN=")" "$(cat "$P/node.env")"
	ok "cp key: pin in node.env (the CP's own agent pins too)" "$(yes_if has_line "$P/node.env" "RASPUTIN_BUS_PIN='$PIN'")" "$(cat "$P/node.env")"
	ok "cp key: key NOT in node.env (name)" "$(yes_if not contains "$P/node.env" RASPUTIN_BUS_KEY)" "$(cat "$P/node.env")"
	ok "cp key: key NOT in node.env (value)" "$(yes_if not contains "$P/node.env" "$KEY")"
	ok "cp key: scrubbed from the seed, left empty" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_KEY=")" "$(cat "$SEED")"
	ok "cp key: value gone from the seed" "$(yes_if not contains "$SEED" "$KEY")"
	ok "cp key: pin kept in the seed" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_PIN=$PIN")" "$(cat "$SEED")"
	ok "cp key: value never logged (stdout)" "$(yes_if not out_has "$KEY")"
	ok "cp key: value never logged (kmsg)" "$(yes_if not contains "$W/kmsg" "$KEY")"
	ok "cp key: seed remounted rw then ro" "$(yes_if test "$(cat "$W/mount.calls")" = "-o remount,rw $M
-o remount,ro $M")" "$(cat "$W/mount.calls")"
	if [ "$HAVE_OPENSSL" = 1 ]; then
		got="sha256/$(openssl base64 -d -A < "$P/bus/bus.key" | openssl pkey -inform der -pubout -outform der 2>/dev/null | openssl dgst -sha256 -binary | openssl base64 -A)"
		ok "cp key: the written file recomputes to the seed's pin (contract recipe)" "$(yes_if test "$got" = "$PIN")" "got $got"
	fi

	# 4. An existing bus.key is never replaced, and the seed is still scrubbed.
	setup; mkdir -p "$P/bus"; printf '%s\n' "$OTHER_KEY" > "$P/bus/bus.key"; chmod 600 "$P/bus/bus.key"
	cp_seed "RASPUTIN_BUS_PIN=$PIN" "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "existing key: provisions" "$RC" "$OUT"
	ok "existing key: not overwritten" "$(yes_if has_line "$P/bus/bus.key" "$OTHER_KEY")" "$(cat "$P/bus/bus.key")"
	ok "existing key: says so" "$(yes_if out_has "already exists and differs")" "$OUT"
	ok "existing key: seed still scrubbed" "$(yes_if not contains "$SEED" "$KEY")" "$(cat "$SEED")"

	setup; mkdir -p "$P/bus"; printf '%s\n' "$KEY" > "$P/bus/bus.key"
	cp_seed "RASPUTIN_BUS_PIN=$PIN" "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "same existing key: provisions quietly" "$(yes_if test "$RC" = 0 -a -n "$(printf '%s' "$OUT" | grep 'already in place')")" "$OUT"

	# A dangling symlink is an existing name too: never written through.
	setup; mkdir -p "$P/bus"; ln -s "$W/elsewhere" "$P/bus/bus.key"
	cp_seed "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "symlinked bus.key: not written through" "$(yes_if not test -e "$W/elsewhere")"

	# 5. A compute seed carrying the key: never written, never in node.env,
	#    scrubbed, warned about; provisioning is not failed over it.
	setup; compute_seed "RASPUTIN_BUS_PIN=$PIN" "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "compute key: provisions" "$RC" "$OUT"
	ok "compute key: no bus.key anywhere" "$(yes_if test -z "$(find "$P" -name 'bus.key*')")" "$(find "$P")"
	ok "compute key: not in node.env" "$(yes_if not contains "$P/node.env" "$KEY")"
	ok "compute key: scrubbed from the seed" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_KEY=")" "$(cat "$SEED")"
	ok "compute key: warned" "$(yes_if out_has "belongs only in the controlplane seed")" "$OUT"
	ok "compute key: value never logged" "$(yes_if not out_has "$KEY")"

	# 6. Surrounding whitespace (a Windows CR, a quoted padded value) is trimmed,
	#    as the agent trims it.
	cr=$(printf '\r')
	setup; compute_seed "RASPUTIN_BUS_PIN=$PIN$cr"; fb
	ok "pin with trailing CR: provisions" "$RC" "$OUT"
	ok "pin with trailing CR: written without it" "$(yes_if has_line "$P/node.env" "RASPUTIN_BUS_PIN='$PIN'")" "$(od -c "$P/node.env" | tail -5)"
	setup; cp_seed "RASPUTIN_BUS_KEY=\"  $KEY$cr\""; printf '%s\n' "$KEY" > "$W/want.key"; fb
	ok "padded key: provisions" "$RC" "$OUT"
	ok "padded key: written trimmed" "$(yes_if cmp -s "$W/want.key" "$P/bus/bus.key")"

	# 7. Every key type the api accepts passes; the DER length header takes all
	#    three encodings (short form, 0x81, 0x82).
	for k in "$TEST_KEY_ED25519" "$TEST_KEY_P256" "$TEST_KEY_RSA"; do
		setup; cp_seed "RASPUTIN_BUS_KEY=$k"; fb
		ok "key type ${k%"${k#????}"}...: accepted and written" "$(yes_if test "$RC" = 0 -a -f "$P/bus/bus.key")" "$OUT"
	done

	# 8. A controlplane pin with no key and no key file: provisions, but warns.
	setup; cp_seed "RASPUTIN_BUS_PIN=$PIN"; fb
	ok "cp pin, no key: provisions" "$RC" "$OUT"
	ok "cp pin, no key: warns" "$(yes_if out_has "no RASPUTIN_BUS_KEY")" "$OUT"

	# 9. Malformed pins fail provisioning loudly, before anything is stamped.
	body=${PIN#sha256/}
	hex=$(printf '%064d' 0)
	urlsafe=$(printf '%s' "$body" | tr '+/' '-_')
	[ "$urlsafe" = "$body" ] && urlsafe="${body%??}_="
	last=${body%=}; last=${last#"${last%?}"}
	case "$last" in B) noncanon=C ;; *) noncanon=B ;; esac
	noncanon="${body%??}$noncanon="
	for bad in \
		"sha256/$hex" \
		"sha256/$urlsafe" \
		"sha256/${body%=}" \
		"SHA256/$body" \
		"sha256//$body" \
		"sha256/${body#?}" \
		"sha256/${body}A" \
		"sha256/$noncanon" \
		"$body" \
		"sha256/${body%??????????}  ${body#??????????}" \
		"sha256/${body%=}==" \
		"sha256/" ; do
		setup; compute_seed "RASPUTIN_BUS_PIN=\"$bad\""; fb
		ok "bad pin '$bad': fails" "$(yes_if test "$RC" != 0)" "$OUT"
		ok "bad pin '$bad': says why" "$(yes_if out_has "is not a valid bus pin")" "$OUT"
		ok "bad pin '$bad': nothing stamped" "$(yes_if not provisioned)"
		ok "bad pin '$bad': no node.env" "$(yes_if not test -e "$P/node.env")"
	done

	# 10. Malformed keys on a controlplane fail loudly: nothing written, nothing
	#     stamped, the seed left as it was (so it can be fixed and re-run), and
	#     the value is never logged.
	for bad in \
		"${KEY%????}" \
		"${KEY}AAAA" \
		"${KEY}${KEY}" \
		"${KEY%?}" \
		"$(printf '%s' "$KEY" | tr '+/' '-_')" \
		"${KEY%??????????}  ${KEY#??????????}" \
		"-----BEGIN PRIVATE KEY-----" \
		"AAAAAAAA" \
		"MIG=" ; do
		# The url-safe mangling is only a malformed case when it changed something.
		[ "$bad" = "$KEY" ] && continue
		setup; cp_seed "RASPUTIN_BUS_PIN=$PIN" "RASPUTIN_BUS_KEY=\"$bad\""; cp "$SEED" "$W/seed.before"; fb
		label="bad key (${#bad} chars)"
		ok "$label: fails" "$(yes_if test "$RC" != 0)" "$OUT"
		ok "$label: says why" "$(yes_if out_has "not a usable bus key")" "$OUT"
		ok "$label: no bus.key" "$(yes_if not test -e "$P/bus/bus.key")"
		ok "$label: nothing stamped" "$(yes_if not provisioned)"
		ok "$label: seed untouched" "$(yes_if cmp -s "$W/seed.before" "$SEED")"
		ok "$label: value never logged" "$(yes_if not out_has "$bad")" "$OUT"
	done

	# 11. A failed scrub never fails provisioning, and the key is still written.
	setup; cp_seed "RASPUTIN_BUS_KEY=$KEY"; STUB_MOUNT_RC=1; fb
	ok "scrub fails: still provisions" "$RC" "$OUT"
	ok "scrub fails: key written" "$(yes_if test -f "$P/bus/bus.key")"
	ok "scrub fails: seed left as it was" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_KEY=$KEY")"

	# 12. When the key cannot be written, provisioning stops — carrying on would
	#     let the api generate a key the nodes do not pin.
	setup; : > "$P/bus"; cp_seed "RASPUTIN_BUS_KEY=$KEY"; fb
	ok "unwritable bus dir: fails" "$(yes_if test "$RC" != 0)" "$OUT"
	ok "unwritable bus dir: says why" "$(yes_if out_has "could not create")" "$OUT"
	ok "unwritable bus dir: nothing stamped" "$(yes_if not provisioned)"
	ok "unwritable bus dir: seed not scrubbed" "$(yes_if has_line "$SEED" "RASPUTIN_BUS_KEY=$KEY")"

	# 13. A join token without a node id fails loudly: the token is bound to a
	#     node id and the bus refuses it under any other, so the node must not
	#     derive one (geekdojo/geekdojo-brain#423). Nothing is written, nothing
	#     stamped, no id minted, and the token stays in the seed for the re-run.
	#     A blank line, a whitespace-only value and a bare CR all count as none.
	for idcase in absent empty spaces cr; do
		case "$idcase" in
			absent) idline="" ;;
			empty)  idline="RASPUTIN_NODE_ID=" ;;
			spaces) idline="RASPUTIN_NODE_ID=\"   \"" ;;
			cr)     idline="RASPUTIN_NODE_ID=$cr" ;;
		esac
		setup
		seed "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_CLUSTER_ID=bench" \
			"RASPUTIN_NATS_URL=nats://bench.local:4222" "RASPUTIN_CP_JOIN_TOKEN=tok-w1" \
			"RASPUTIN_BUS_PIN=$PIN" "$idline"
		cp "$SEED" "$W/seed.before"; fb
		label="token, no node id ($idcase)"
		ok "$label: fails" "$(yes_if test "$RC" != 0)" "$OUT"
		ok "$label: says why" "$(yes_if out_has "carries a join token but no RASPUTIN_NODE_ID")" "$OUT"
		ok "$label: nothing stamped" "$(yes_if not provisioned)"
		ok "$label: no node.env" "$(yes_if not test -e "$P/node.env")"
		ok "$label: no id minted" "$(yes_if not test -e "$P/node-id.rand")" "$(ls -A "$P")"
		ok "$label: seed untouched (token not scrubbed)" "$(yes_if cmp -s "$W/seed.before" "$SEED")" "$(cat "$SEED")"
		ok "$label: no mount calls" "$(yes_if test ! -s "$W/mount.calls")" "$(cat "$W/mount.calls")"
	done

	# 14. The same seed with its node id: provisions exactly as before, with the
	#     seed's id and token in node.env and the token scrubbed.
	setup; compute_seed; fb
	ok "token + node id: provisions" "$RC" "$OUT"
	ok "token + node id: stamped" "$(yes_if provisioned)"
	ok "token + node id: node.env carries the seed's id" "$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID='w1'")" "$(cat "$P/node.env")"
	ok "token + node id: no id minted" "$(yes_if not test -e "$P/node-id.rand")"

	# 14b. The token is at rest in ONE 0600 file, and node.env only names it
	#      (geekdojo/geekdojo-brain#537, §7 4.1). Nothing is left in the
	#      environment block the agent and every child it spawns inherit.
	printf '%s\n' "tok-w1" > "$W/want.token"
	ok "token file: holds the seed's token verbatim plus one newline" "$(yes_if cmp -s "$W/want.token" "$P/bus/join.token")" "$(cat "$P/bus/join.token" 2>&1)"
	ok "token file: is 0600" "$(yes_if test "$(perms "$P/bus/join.token")" = "-rw-------")" "$(perms "$P/bus/join.token")"
	ok "token file: bus dir is 0700" "$(yes_if test "$(perms "$P/bus")" = "drwx------")" "$(perms "$P/bus")"
	ok "token file: no temp file left beside it" "$(yes_if test "$(ls -A "$P/bus")" = "join.token")" "$(ls -A "$P/bus")"
	ok "token file: node.env names it" "$(yes_if has_line "$P/node.env" "RASPUTIN_CP_JOIN_TOKEN_FILE='$P/bus/join.token'")" "$(cat "$P/node.env")"
	ok "token file: node.env carries no inline token" "$(yes_if not grep -q '^RASPUTIN_CP_JOIN_TOKEN=' "$P/node.env")" "$(cat "$P/node.env")"
	ok "token file: the token value is not in node.env at all" "$(yes_if not contains "$P/node.env" "tok-w1")" "$(cat "$P/node.env")"
	ok "token file: never logged (stdout)" "$(yes_if not out_has "tok-w1")"
	ok "token file: never logged (kmsg)" "$(yes_if not contains "$W/kmsg" "tok-w1")"

	# 15. The kernel command line CANNOT name a node any more
	#     (geekdojo/geekdojo-brain#540, M27). rasputin.id= used to provision a
	#     seed that carried a token and no id; a node's identity now comes
	#     from its seed and from nothing else, so the same boot fails the way
	#     any seed with no id fails.
	setup
	seed "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NATS_URL=nats://bench.local:4222" "RASPUTIN_CP_JOIN_TOKEN=tok-w2"
	printf 'quiet rasputin.id=w2 rasputin.role=controlplane rasputin.nats=nats://evil.local:4222\n' > "$W/cmdline"; fb
	ok "cmdline id: no longer provisions" "$(yes_if test "$RC" != 0)" "$OUT"
	ok "cmdline id: says the seed carries no node id" "$(yes_if out_has "no RASPUTIN_NODE_ID")" "$OUT"
	ok "cmdline id: nothing was written" "$(yes_if not test -f "$P/node.env")" "$(cat "$P/node.env" 2>&1)"

	# And with a COMPLETE seed, a command line naming another role, id and bus
	# changes nothing: the seed wins because it is the only source.
	setup
	compute_seed
	printf 'quiet rasputin.id=impostor rasputin.role=controlplane rasputin.nats=nats://evil.local:4222\n' > "$W/cmdline"; fb
	ok "cmdline override: provisions from the seed" "$RC" "$OUT"
	ok "cmdline override: the id is the seed's" "$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID='w1'")" "$(cat "$P/node.env" 2>&1)"
	ok "cmdline override: the role is the seed's" "$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ROLE='compute'")" "$(cat "$P/node.env" 2>&1)"
	ok "cmdline override: the bus is the seed's" "$(yes_if has_line "$P/node.env" "RASPUTIN_NATS_URL='nats://bench.local:4222'")" "$(cat "$P/node.env" 2>&1)"
	ok "cmdline override: no controlplane marker" "$(yes_if not test -f "$P/role.controlplane")" "$(ls -a "$P")"

	# 15b. The seed is read THROUGH the agent, not sourced as a shell script
	#      (geekdojo/geekdojo-brain#540, F18). The three exit statuses are the
	#      contract, and each one means something different to firstboot.

	# 0 — checked. What firstboot uses is the agent's OUTPUT, not the file on
	# the volume. Proven by having the stub answer with a different node id
	# than the seed carries: if node.env says the stub's, the raw file was not
	# what was sourced.
	setup; agent_stub "cat <<'CHECKED'
RASPUTIN_NODE_ROLE='compute'
RASPUTIN_NODE_ID='from-the-agent'
RASPUTIN_CLUSTER_ID='bench'
RASPUTIN_NATS_URL='nats://bench.local:4222'
RASPUTIN_CP_JOIN_TOKEN='tok-checked'
CHECKED"
	compute_seed; fb
	ok "seed check: provisions" "$RC" "$OUT"
	ok "seed check: the normalized copy is what was sourced" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID='from-the-agent'")" "$(cat "$P/node.env" 2>&1)"
	ok "seed check: says it checked the seed" "$(yes_if out_has "seed checked by")" "$OUT"
	# The normalized copy holds the join token, so it does not outlive the read.
	ok "seed check: the checked copy is removed" \
		"$(yes_if not test -e "$P/.seed-checked.env")" "$(ls -a "$P")"
	ok "seed check: and so is its stderr" \
		"$(yes_if not test -e "$P/.seed-checked.env.err")" "$(ls -a "$P")"
	ok "seed check: the checked token never reaches node.env" \
		"$(yes_if not contains "$P/node.env" "tok-checked")" "$(cat "$P/node.env")"

	# 1 — the agent refuses the seed. Provisioning STOPS, the node is left
	# unprovisioned so firstboot re-runs once the seed is fixed, and the
	# agent's own reason is what the console shows.
	setup; agent_stub "echo 'SEED UNUSABLE: RASPUTIN_NODE_ID is \"Node_1\", which is not a usable node id' >&2; exit 1"
	compute_seed; fb
	ok "seed refused: fails" "$(yes_if test "$RC" != 0)" "$OUT"
	ok "seed refused: relays the agent's reason" "$(yes_if out_has "SEED UNUSABLE")" "$OUT"
	ok "seed refused: nothing written" "$(yes_if not test -f "$P/node.env")" "$(cat "$P/node.env" 2>&1)"
	ok "seed refused: not stamped, so firstboot re-runs" "$(yes_if not provisioned)" "$(ls -a "$P")"
	ok "seed refused: no temp files left behind" \
		"$(yes_if not test -e "$P/.seed-checked.env")" "$(ls -a "$P")"

	# 2 — an agent that predates the subcommand. MIXED FLEETS: an image can
	# carry an agent a release behind, and a node must not fail to provision
	# for it. Falls back to reading the seed directly, and says so.
	setup; agent_stub "exit 2"
	compute_seed; fb
	ok "old agent: still provisions" "$RC" "$OUT"
	ok "old agent: says it fell back" "$(yes_if out_has "does not support 'seed check'")" "$OUT"
	ok "old agent: the seed's own values are used" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID='w1'")" "$(cat "$P/node.env" 2>&1)"

	# An agent that does not know ANY of this — the literal shape of an older
	# build, which answers an unknown command on stderr with exit 2.
	setup; agent_stub "echo unreachable"
	compute_seed
	printf '#!/bin/sh\necho "rasputin-agent: unknown command \\"$1\\"" >&2\nexit 2\n' > "$AGENT"
	chmod +x "$AGENT"; fb
	ok "unknown command: still provisions" "$RC" "$OUT"
	ok "unknown command: says it fell back" "$(yes_if out_has "does not support 'seed check'")" "$OUT"

	# No agent on the image at all: the same fallback, named differently so
	# the two are not confused in a console log.
	setup
	compute_seed; fb
	ok "no agent: still provisions" "$RC" "$OUT"
	ok "no agent: says there is no agent" "$(yes_if out_has "no agent at")" "$OUT"
	ok "no agent: the seed's own values are used" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_NODE_ID='w1'")" "$(cat "$P/node.env" 2>&1)"

	# 15c. node.env quotes EVERY value (geekdojo/geekdojo-brain#540). The file
	#      is sourced by sh on every boot — rasputin-hostname and
	#      rasputin-timesync-apply read it, and systemd hands it to the agent —
	#      so a value a shell would act on has to come back as data.
	setup; agent_stub "cat <<'CHECKED'
RASPUTIN_NODE_ROLE='compute'
RASPUTIN_NODE_ID='w1'
RASPUTIN_CLUSTER_ID='bench'
RASPUTIN_NATS_URL='nats://bench.local:4222'
RASPUTIN_CP_JOIN_TOKEN='tok-w1'
RASPUTIN_NTP_SERVER='ntp1.example 10.0.0.1'
CHECKED"
	compute_seed; fb
	ok "quoting: provisions" "$RC" "$OUT"
	ok "quoting: a value with spaces is quoted" \
		"$(yes_if has_line "$P/node.env" "RASPUTIN_NTP_SERVER='ntp1.example 10.0.0.1'")" "$(cat "$P/node.env" 2>&1)"
	ok "quoting: every line is KEY='value'" \
		"$(yes_if not grep -qvE "^[A-Z_]+='.*'$" "$P/node.env")" "$(cat "$P/node.env")"
	# Sourced back by a real shell, the value is the value — and nothing runs.
	got=$(sh -c ". '$P/node.env'; printf '%s' \"\$RASPUTIN_NTP_SERVER\"" 2>/dev/null)
	ok "quoting: sourcing node.env gives a spaced value back whole" \
		"$(yes_if test "$got" = "ntp1.example 10.0.0.1")" "got=<$got>"

	# And a value that WOULD run if it were not quoted. RASPUTIN_NATS_URL is
	# the one field that reaches node.env with no validation or sanitizing of
	# its own — the node id is canonicalised, the cluster id is a DNS label,
	# the NTP server and the fallback address are filtered to their alphabets
	# — so it is where the quoting is the only thing standing between a seed
	# and a root shell on every boot.
	#
	# Written into the raw seed, single-quoted there, so the value that
	# reaches firstboot is the literal text and not the result of running it.
	setup
	seed "RASPUTIN_NODE_ROLE=compute" "RASPUTIN_NODE_ID=w1" "RASPUTIN_CLUSTER_ID=bench" \
		"RASPUTIN_NATS_URL='\$(touch $W/node-env-canary)'" "RASPUTIN_CP_JOIN_TOKEN=tok-w1"
	fb
	ok "quoting: a hostile bus URL still provisions" "$RC" "$OUT"
	rm -f "$W/node-env-canary"
	sh -c ". '$P/node.env'" >/dev/null 2>&1 || true
	ok "quoting: sourcing node.env runs nothing" \
		"$(yes_if not test -e "$W/node-env-canary")" "$(cat "$P/node.env" 2>&1)"
	got=$(sh -c ". '$P/node.env'; printf '%s' \"\$RASPUTIN_NATS_URL\"" 2>/dev/null)
	ok "quoting: the hostile value comes back as data" \
		"$(yes_if test "$got" = "\$(touch $W/node-env-canary)")" "got=<$got>"

	# 16. A controlplane seed with no node id still fails, with its own message.
	setup
	seed "RASPUTIN_NODE_ROLE=controlplane" "RASPUTIN_CLUSTER_ID=bench" "RASPUTIN_BUS_AUTH=enforce"
	fb
	ok "cp, no node id: fails" "$(yes_if test "$RC" != 0)" "$OUT"
	ok "cp, no node id: says why" "$(yes_if out_has "the controlplane must be named")" "$OUT"
	ok "cp, no node id: nothing stamped" "$(yes_if not provisioned)"
	ok "cp, no node id: no role marker" "$(yes_if not test -e "$P/role.controlplane")"
}

for SH in $TEST_SHELLS; do
	echo "== $SH"
	cases
done

# The api unit must not pin the TLS ladder: RASPUTIN_BUS_TLS set in the unit
# would lock every controlplane to one mode (the api refuses changes when the
# variable is set). Shell-independent, so checked once.
SH=unit
ok "rasputin-api.service does not set RASPUTIN_BUS_TLS" \
	"$(yes_if not grep -Eq '^[[:space:]]*Environment=.*RASPUTIN_BUS_TLS' "$API_UNIT")"
ok "rasputin-api.service data dir is where bus.key is written" \
	"$(yes_if grep -qx 'Environment=RASPUTIN_DATA_DIR=/var/lib/rasputin' "$API_UNIT")"
# The api mints its own agent's bus token before it reports ready
# (geekdojo-brain#140); the agent must be ordered after it so its first connect
# finds the file.
ok "rasputin-agent.service starts after rasputin-api.service" \
	"$(yes_if grep -Eq '^After=.*[[:space:]]rasputin-api\.service([[:space:]]|$)' "$AGENT_UNIT")"

echo "firstboot: $pass passed, $fail failed (shells:$TEST_SHELLS)"
[ "$fail" -eq 0 ]
