#!/bin/sh
#
# Tests for test/resolved-mdns-loopback.sh — the check that systemd-resolved's
# on_mdns_packet() drops looped-back packets from the host's own addresses
# before it handles replies (geekdojo/geekdojo-brain#1067).
#
# Why. The check guards the image's systemd patch against a Buildroot bump that
# brings the regression back with no patch for the new version. So it must tell
# the fixed shape (v258.8, or v258.7 with the patch) from the broken one (v258.7
# unpatched), and it must fail, never pass, when it cannot decide. The fixtures
# below are cut-down copies of on_mdns_packet() in those two shapes. Whether the
# patch reaches the real source is the resolved-mdns-loopback job in ci.yml.
#
# Run:  sh test/resolved-mdns-loopback-test.sh
set -u

REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$REPO/test/resolved-mdns-loopback.sh"
[ -f "$SCRIPT" ] || { echo "missing: $SCRIPT" >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() {
	if [ "$2" = "$3" ]; then pass=$((pass + 1)); else
		fail=$((fail + 1)); printf '  FAIL %s\n       want: %s\n       got:  %s\n' "$1" "$2" "$3" >&2
	fi
}
has() { case "$1" in *"$2"*) echo yes ;; *) echo no ;; esac; }
rc_of() { echo "${1##*|rc=}"; }
errors() { printf '%s\n' "${1%|rc=*}" | grep -c '^::error::'; }

# run [ARG...] — the check's output, then "|rc=<status>".
run() { _out=$(sh "$SCRIPT" "$@" 2>&1); printf '%s|rc=%s' "$_out" "$?"; }

# --- fixtures -----------------------------------------------------------------------
# v258.8 shape: the local-host filter at the top, before the reply/query split.
cat > "$TMP/fixed.c" <<'EOF'
static int mdns_scope_process_query(DnsScope *s, DnsPacket *p) {
        return 0;
}

static int on_mdns_packet(sd_event_source *s, int fd, uint32_t revents, void *userdata) {
        Manager *m = userdata;
        int r;

        r = manager_recv(m, fd, DNS_PROTOCOL_MDNS, &p);
        if (r <= 0)
                return r;

        if (p->sender_port == MDNS_PORT && manager_packet_from_local_address(m, p)) {
                log_debug("Got mDNS UDP packet from local host, ignoring.");
                return 0;
        }

        if (dns_packet_validate_reply(p) > 0) {
                log_debug("Got mDNS reply packet");
        } else if (dns_packet_validate_query(p) > 0)  {
                r = mdns_scope_process_query(scope, p);
        }

        return 0;
}
EOF

# v258.7 shape: replies handled first; the filter only inside the query branch.
cat > "$TMP/broken.c" <<'EOF'
static int on_mdns_packet(sd_event_source *s, int fd, uint32_t revents, void *userdata) {
        Manager *m = userdata;
        int r;

        r = manager_recv(m, fd, DNS_PROTOCOL_MDNS, &p);
        if (r <= 0)
                return r;

        if (dns_packet_validate_reply(p) > 0) {
                log_debug("Got mDNS reply packet");
        } else if (dns_packet_validate_query(p) > 0)  {
                if (p->sender_port == MDNS_PORT && manager_packet_from_local_address(m, p)) {
                        log_debug("Got mDNS UDP packet from local host, ignoring.");
                        return 0;
                }
                r = mdns_scope_process_query(scope, p);
        }

        return 0;
}
EOF

# --- TC-1067-01: the fixed shape passes, the broken shape fails naming the property --
echo "== fixed and broken shapes"
out=$(run "$TMP/fixed.c")
check "TC-1067-01 v258.8 shape: exit 0" "0" "$(rc_of "$out")"
check "TC-1067-01 v258.8 shape: no error" "0" "$(errors "$out")"
check "TC-1067-01 v258.8 shape: ok line with both lines" "yes" "$(has "$out" "ok  $TMP/fixed.c: on_mdns_packet() drops packets from the local host (line 13) before it handles replies (line 18).")"

out=$(run "$TMP/broken.c")
check "TC-1067-01 v258.7 shape: exit 1" "1" "$(rc_of "$out")"
check "TC-1067-01 v258.7 shape: one error" "1" "$(errors "$out")"
check "TC-1067-01 v258.7 shape: the sentence names file, function and property" "yes" "$(has "$out" "::error::resolved-mdns-loopback: In $TMP/broken.c, on_mdns_packet() checks for packets from the local host (manager_packet_from_local_address at line 12) only after it handles replies (dns_packet_validate_reply at line 9), so resolved accepts its own looped-back mDNS replies and can rename the host.")"
check "TC-1067-01 v258.7 shape: no ok line" "no" "$(has "$out" "ok  ")"

# --- TC-1067-02: it fails closed when it cannot decide (exit 1) ----------------------
echo "== cannot decide"
CANNOT="so it cannot be decided whether resolved drops its own looped-back mDNS packets before handling replies. Upstream may have refactored it; re-check the source by hand."

# The function is absent (renamed upstream), and an empty file.
sed 's/on_mdns_packet(/on_mdns_datagram(/' "$TMP/fixed.c" > "$TMP/nofn.c"
: > "$TMP/empty.c"
for f in nofn empty; do
	out=$(run "$TMP/$f.c")
	check "TC-1067-02 $f: exit 1" "1" "$(rc_of "$out")"
	check "TC-1067-02 $f: the sentence" "yes" "$(has "$out" "::error::resolved-mdns-loopback: $TMP/$f.c has no on_mdns_packet() function, $CANNOT")"
done

# The local-address call absent from the body.
sed 's/manager_packet_from_local_address(m, p)/manager_packet_is_ours(m, p)/' "$TMP/fixed.c" > "$TMP/nolocal.c"
out=$(run "$TMP/nolocal.c")
check "TC-1067-02 no local-address call: exit 1" "1" "$(rc_of "$out")"
check "TC-1067-02 no local-address call: the sentence" "yes" "$(has "$out" "::error::resolved-mdns-loopback: The on_mdns_packet() function in $TMP/nolocal.c never calls manager_packet_from_local_address(), $CANNOT")"

# The reply validation absent from the body.
sed 's/dns_packet_validate_reply(p)/dns_packet_is_reply(p)/' "$TMP/fixed.c" > "$TMP/noreply.c"
out=$(run "$TMP/noreply.c")
check "TC-1067-02 no reply validation: exit 1" "1" "$(rc_of "$out")"
check "TC-1067-02 no reply validation: the sentence" "yes" "$(has "$out" "::error::resolved-mdns-loopback: The on_mdns_packet() function in $TMP/noreply.c never calls dns_packet_validate_reply(), $CANNOT")"

# The body bounds hold. Neither call is in on_mdns_packet(); both follow its
# closing column-0 "}", the local-address call first, in a later function. A
# check that read past the "}" would find them in the passing order and exit 0.
cat > "$TMP/after.c" <<'EOF'
static int on_mdns_packet(sd_event_source *s, int fd, uint32_t revents, void *userdata) {
        log_debug("Got mDNS packet");
        return 0;
}

static int mdns_packet_classify(Manager *m, DnsPacket *p) {
        if (manager_packet_from_local_address(m, p))
                return 0;
        return dns_packet_validate_reply(p);
}
EOF
out=$(run "$TMP/after.c")
check "TC-1067-02 local-address call only after the body: exit 1" "1" "$(rc_of "$out")"
check "TC-1067-02 local-address call only after the body: said as missing from the function" "yes" "$(has "$out" "::error::resolved-mdns-loopback: The on_mdns_packet() function in $TMP/after.c never calls manager_packet_from_local_address(), $CANNOT")"

# --- TC-1067-02: no input, or not a readable file (exit 2) ---------------------------
echo "== bad input"
out=$(run)
check "TC-1067-02 no argument: exit 2" "2" "$(rc_of "$out")"
check "TC-1067-02 no argument: said" "yes" "$(has "$out" "::error::resolved-mdns-loopback: No input file was given. Usage: resolved-mdns-loopback.sh <path to src/resolve/resolved-mdns.c>.")"
for bad in "$TMP/no-such-file.c" "$TMP"; do
	out=$(run "$bad")
	check "TC-1067-02 $bad: exit 2" "2" "$(rc_of "$out")"
	check "TC-1067-02 $bad: said" "yes" "$(has "$out" "::error::resolved-mdns-loopback: The input $bad is not a readable file, so it cannot be checked.")"
done

echo "resolved-mdns-loopback: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
