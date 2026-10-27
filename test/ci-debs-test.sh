#!/usr/bin/env bash
#
# ci-debs-test.sh — scripts/ci-debs.sh, against local HTTP mirrors.
#
# WHY
#   ci-debs.sh is what stands between every package install in release.yml
#   (the boot smokes, the update smokes, sign) and ci.yml (verify-bundle) and a
#   mirror that trickles (2026-10-27, geekdojo/rasputin-openwrt-firewall run
#   40537097987: 37.6 kB/s for 24 MB, step timed out). This is a copy of that
#   repo's scripts/test-ci-debs.sh, kept in step with the script it tests. Its whole
#   value is in the refusals: a trickling mirror abandoned in seconds instead of
#   minutes, a truncated or tampered file refused rather than installed, a cached
#   set whose checksums do not match refused before apt sees it, and an exit
#   that is never zero when nothing was fetched. So most cases here are failure
#   paths, run against REAL local HTTP servers (python3 http.server), not mocks:
#     - a good mirror           -> file fetched, size and hash checked
#     - a mirror that trickles  -> abandoned on the speed floor, next mirror used
#     - a mirror serving 404    -> next mirror used
#     - a mirror serving wrong bytes of the right size -> hash refusal, next mirror
#     - a truncated file        -> size refusal, next mirror
#     - every mirror bad        -> non-zero exit and a ::error:: naming each mirror
#     - --print-uris parsing    -> plain and mirror+file: URIs, a missing size/hash
#     - install                 -> refuses a missing SHA256SUMS, a tampered .deb,
#                                  and an unlisted .deb, all before apt runs
#     - key                     -> stable, and changes with the package list
#                                  (needs dpkg-query; REQUIRE_DPKG=1 makes a
#                                  missing one a failure, as CI sets it)
#
# Needs python3 and curl. No internet. Run: bash test/ci-debs-test.sh

set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
CD="$PWD/scripts/ci-debs.sh"

fail=0
ok()  { printf '  ok   %s\n' "$*"; }
bad() { printf '  ✗    %s\n' "$*" >&2; fail=$((fail + 1)); }

command -v python3 >/dev/null 2>&1 || { echo "✗ python3 is required" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "✗ curl is required" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ci-debs-test.XXXXXX")"
WORK="$(cd "$WORK" && pwd)"   # no doubled slash from a TMPDIR ending in /
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
md5h() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'; else md5 -q "$1"; fi; }

# The payload: 64 KiB, so a trickle at 1 KiB/s cannot finish inside the test.
POOL="pool/main/f/foo/foo_1.0_amd64.deb"
for d in good wrong short; do mkdir -p "$WORK/$d/$(dirname "$POOL")"; done
head -c 65536 /dev/urandom > "$WORK/good/$POOL"
SIZE="$(wc -c < "$WORK/good/$POOL" | tr -d ' ')"
SHA="$(sha256 "$WORK/good/$POOL")"
MD5="$(md5h "$WORK/good/$POOL")"
head -c 65536 /dev/urandom > "$WORK/wrong/$POOL"      # right size, wrong bytes
head -c 1000 "$WORK/good/$POOL" > "$WORK/short/$POOL"  # truncated

# Mirrors: a static server per directory, a trickling server, and a 404 server.
cat > "$WORK/srv.py" <<'PY'
import http.server, os, sys, time
mode, root = sys.argv[1], sys.argv[2]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=root, **k)
    def log_message(self, *a): pass
    def do_GET(self):
        if mode == "404":
            self.send_error(404); return
        if mode == "trickle":
            p = os.path.join(root, self.path.lstrip("/"))
            data = open(p, "rb").read()
            self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
            try:
                for i in range(0, len(data), 64):
                    self.wfile.write(data[i:i+64]); self.wfile.flush(); time.sleep(0.1)
            except (BrokenPipeError, ConnectionResetError):
                pass
            return
        super().do_GET()
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
print(s.server_address[1], flush=True)
s.serve_forever()
PY
start() { # start <name> <mode> <root>
	python3 -u "$WORK/srv.py" "$2" "$3" > "$WORK/$1.port" 2>/dev/null &
	PIDS="$PIDS $!"
	local _i; for _i in $(seq 1 50); do [ -s "$WORK/$1.port" ] && break; sleep 0.1; done
	[ -s "$WORK/$1.port" ] || { echo "✗ test server $1 did not start" >&2; exit 1; }
	eval "$1=http://127.0.0.1:$(head -1 "$WORK/$1.port")"
}
start GOOD static "$WORK/good"
start WRONG static "$WORK/wrong"
start SHORT static "$WORK/short"
start TRICKLE trickle "$WORK/good"
start MISSING 404 "$WORK/good"

# get <mirrors> <hash> -> RC, OUT, and $WORK/out.deb
get() {
	rm -f "$WORK/out.deb"
	OUT="$(CI_DEBS_MIRRORS="$1" CI_DEBS_SPEED_LIMIT=20000 CI_DEBS_SPEED_TIME=2 CI_DEBS_MAX_TIME=20 \
		"$CD" get "$POOL" "$SIZE" "$2" "$WORK/out.deb" 2>&1)"
	RC=$?
}
fetched_ok() { [ "$RC" -eq 0 ] && [ -f "$WORK/out.deb" ] && [ "$(sha256 "$WORK/out.deb")" = "$SHA" ]; }

echo "get: one pool file through the mirror list"
get "$GOOD" "SHA256:$SHA"
if fetched_ok; then ok "good mirror: fetched and verified (SHA256)"; else bad "good mirror: rc=$RC $OUT"; fi
get "$GOOD" "MD5Sum:$MD5"
if fetched_ok; then ok "good mirror: fetched and verified (MD5Sum, as apt prints it)"; else bad "MD5Sum: rc=$RC $OUT"; fi

t0="$(date +%s)"
get "$TRICKLE $GOOD" "SHA256:$SHA"
dt=$(( $(date +%s) - t0 ))
if fetched_ok && printf '%s' "$OUT" | grep -q "$TRICKLE: slower than"; then
	ok "trickling mirror abandoned on the speed floor after ${dt}s, next mirror used"
else bad "trickle: rc=$RC ${dt}s $OUT"; fi

get "$MISSING $GOOD" "SHA256:$SHA"
if fetched_ok && printf '%s' "$OUT" | grep -q "HTTP error"; then ok "404 mirror skipped"; else bad "404: rc=$RC $OUT"; fi

get "$WRONG $GOOD" "SHA256:$SHA"
if fetched_ok && printf '%s' "$OUT" | grep -q "SHA256 .*index says"; then ok "wrong bytes refused on hash, next mirror used"; else bad "wrong bytes: rc=$RC $OUT"; fi

get "$SHORT $GOOD" "SHA256:$SHA"
if fetched_ok && printf '%s' "$OUT" | grep -q "size 1000, index says"; then ok "truncated file refused on size, next mirror used"; else bad "short: rc=$RC $OUT"; fi

get "$TRICKLE $WRONG $MISSING" "SHA256:$SHA"
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/out.deb" ] && [ ! -e "$WORK/out.deb.part" ] \
	&& printf '%s' "$OUT" | grep -q "::error::could not fetch $POOL from any mirror:.*$TRICKLE.*$WRONG.*$MISSING"; then
	ok "every mirror bad: non-zero, no file left behind, ::error:: names all three"
else bad "all bad: rc=$RC $OUT"; fi

get "$GOOD" "CRC32:abcd"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "unsupported hash type"; then ok "unknown hash type refused"; else bad "hash type: rc=$RC $OUT"; fi

echo "parse-uris: apt-get --print-uris output"
OUT="$(printf '%s\n' \
	"'http://azure.archive.ubuntu.com/ubuntu/pool/main/q/qemu/qemu-system-x86_1%3a10.2.1_amd64.deb' qemu-system-x86_1%3a10.2.1_amd64.deb 11500000 MD5Sum:0123" \
	"'mirror+file:/etc/apt/apt-mirrors.txt/pool/main/e/edk2/ovmf_2025.11_all.deb' ovmf_2025.11_all.deb 6832 SHA256:abcd" \
	| "$CD" parse-uris 2>&1)"; RC=$?
want="pool/main/q/qemu/qemu-system-x86_1%3a10.2.1_amd64.deb qemu-system-x86_1%3a10.2.1_amd64.deb 11500000 MD5Sum:0123
pool/main/e/edk2/ovmf_2025.11_all.deb ovmf_2025.11_all.deb 6832 SHA256:abcd"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$want" ]; then ok "plain and mirror+file: URIs reduce to the pool path"; else bad "parse: rc=$RC $OUT"; fi
OUT="$(printf '%s\n' "'http://x/ubuntu/dists/foo.deb' foo.deb 10 SHA256:ab" | "$CD" parse-uris 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "no /pool/ path"; then ok "URI without /pool/ refused"; else bad "no pool: rc=$RC $OUT"; fi
OUT="$(printf '%s\n' "'http://x/pool/f.deb' f.deb" | "$CD" parse-uris 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "no size"; then ok "line with no size refused"; else bad "no size: rc=$RC $OUT"; fi
OUT="$(printf '%s\n' "'http://x/pool/f.deb' f.deb 10" | "$CD" parse-uris 2>&1)"; RC=$?
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "no hash"; then ok "line with no hash refused"; else bad "no hash: rc=$RC $OUT"; fi

echo "install: the cached set is verified before apt sees it"
# A sudo that records instead of running, so a refusal that wrongly reaches
# apt shows up as a recorded call rather than an attempted install.
mkdir -p "$WORK/bin"; printf '#!/bin/sh\necho "$@" >> "%s/sudo.calls"\n' "$WORK" > "$WORK/bin/sudo"; chmod +x "$WORK/bin/sudo"
inst() { rm -f "$WORK/sudo.calls"; OUT="$(PATH="$WORK/bin:$PATH" "$CD" install "$1" 2>&1)"; RC=$?; }
C="$WORK/cache"; mkdir -p "$C"
cp "$WORK/good/$POOL" "$C/foo.deb"
inst "$C"
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/sudo.calls" ] && printf '%s' "$OUT" | grep -q "SHA256SUMS is missing"; then ok "missing SHA256SUMS refused"; else bad "no sums: rc=$RC $OUT"; fi
printf '%s  foo.deb\n' "$SHA" > "$C/SHA256SUMS"
inst "$C"
if [ "$RC" -eq 0 ] && grep -q "apt-get install .*--no-download.* /var/cache/apt/archives/foo.deb" "$WORK/sudo.calls"; then ok "verified set handed to apt-get --no-download"; else bad "good set: rc=$RC $OUT / calls: $(cat "$WORK/sudo.calls" 2>/dev/null)"; fi
printf 'x' >> "$C/foo.deb"
inst "$C"
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/sudo.calls" ] && printf '%s' "$OUT" | grep -q "refusing to install"; then ok "tampered .deb refused"; else bad "tampered: rc=$RC $OUT"; fi
cp "$WORK/good/$POOL" "$C/foo.deb"; cp "$WORK/wrong/$POOL" "$C/extra.deb"
inst "$C"
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/sudo.calls" ] && printf '%s' "$OUT" | grep -q "does not list"; then ok "unlisted .deb refused"; else bad "unlisted: rc=$RC $OUT"; fi
rm -f "$C/extra.deb"; rm -f "$C/foo.deb"
inst "$C"
if [ "$RC" -ne 0 ] && [ ! -e "$WORK/sudo.calls" ] && printf '%s' "$OUT" | grep -q "missing foo.deb"; then ok "listed but missing .deb refused"; else bad "missing deb: rc=$RC $OUT"; fi

echo "key: the cache key"
if command -v dpkg-query >/dev/null 2>&1; then
	k1="$("$CD" key qemu-system-x86 ovmf)"; k2="$("$CD" key qemu-system-x86 ovmf)"; k3="$("$CD" key qemu-system-x86)"
	if [ "${#k1}" -eq 64 ] && [ "$k1" = "$k2" ]; then ok "key is a stable sha256"; else bad "key unstable: $k1 / $k2"; fi
	if [ "$k1" != "$k3" ]; then ok "key changes with the package list"; else bad "key ignores the package list"; fi
elif [ "${REQUIRE_DPKG:-0}" = 1 ]; then
	bad "dpkg-query not found and REQUIRE_DPKG=1"
else
	echo "  skip key cases: no dpkg-query on this machine (CI sets REQUIRE_DPKG=1)"
fi

if [ "$fail" -ne 0 ]; then echo "✗ $fail case(s) failed" >&2; exit 1; fi
echo "all ci-debs cases passed"
