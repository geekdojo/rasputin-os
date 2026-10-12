#!/bin/sh
#
# api-session.sh — sign in to a freshly provisioned control plane's api through
# first-run registration, so the boot smoke can read a route behind a session
# (geekdojo/geekdojo-brain#834). Sourced, never run.
#
# First-run registration is open until a user exists, and its finish step is
# the api's only way to issue a session (rasputin-control-plane
# api/internal/auth/handlers.go). The browser's part of the ceremony is played
# by test/lib/soft-passkey.py, a "none" attestation over a P-256 public key
# that openssl makes; the private key only ever passes through a pipe.
#
#   api_session POST BASE ORIGIN JAR WORK
#       POST is a function, called as POST URL BODYFILE OUTFILE JAR, that
#       sends BODYFILE as JSON with the cookie JAR, writes the answer's body to
#       OUTFILE and prints the HTTP status code (000 or nothing for no answer).
#       BASE is the api's scheme, host and port; ORIGIN is the origin the
#       passkey claims (https:// and the RP ID); WORK is a scratch directory.
#       Returns 0 once the jar holds a rasputin-session cookie. Otherwise prints
#       one sentence saying which step failed and returns 1. The sentence never
#       holds a response body, the challenge or a cookie value. Every file it
#       makes under WORK is removed on every path; the jar is the caller's.
#
# The sourcing script sets SOFT_PASSKEY to the path of soft-passkey.py.

api_session() {
	_as_post=$1
	_as_base=$2
	_as_origin=$3
	_as_jar=$4
	_as_work=$5
	_api_session_steps
	_as_rc=$?
	rm -f "$_as_work/begin.req" "$_as_work/begin.out" "$_as_work/pk.der" \
		"$_as_work/finish.req" "$_as_work/finish.out" "$_as_work/passkey.err"
	return "$_as_rc"
}

# _api_session_steps — the ceremony, step by step, for api_session, which
# cleans up after it whichever step it stops at.
_api_session_steps() {
	printf '%s' '{"name":"smoke","displayName":"Smoke Test"}' > "$_as_work/begin.req"
	_as_code=$("$_as_post" "$_as_base/api/auth/register/begin" "$_as_work/begin.req" "$_as_work/begin.out" "$_as_jar")
	case "$_as_code" in
		'' | 000) echo "The api's register/begin gave no HTTP answer."; return 1 ;;
		200) ;;
		*) echo "The api's register/begin answered HTTP $_as_code."; return 1 ;;
	esac
	if ! jq -e '.publicKey.challenge | type == "string" and length > 0' "$_as_work/begin.out" >/dev/null 2>&1; then
		echo "The registration options from register/begin carry no challenge."; return 1
	fi
	if ! jq -e '.publicKey.rp.id | type == "string" and length > 0' "$_as_work/begin.out" >/dev/null 2>&1; then
		echo "The registration options from register/begin carry no rp.id."; return 1
	fi

	openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null \
		| openssl ec -pubout -outform DER > "$_as_work/pk.der" 2>/dev/null
	if [ ! -s "$_as_work/pk.der" ]; then
		echo "OpenSSL could not make a P-256 public key."; return 1
	fi

	if ! python3 -I "$SOFT_PASSKEY" --origin "$_as_origin" --pubkey-der "$_as_work/pk.der" \
		< "$_as_work/begin.out" > "$_as_work/finish.req" 2> "$_as_work/passkey.err"; then
		echo "The soft passkey could not encode the registration: $(head -n 1 "$_as_work/passkey.err")"
		return 1
	fi

	_as_code=$("$_as_post" "$_as_base/api/auth/register/finish" "$_as_work/finish.req" "$_as_work/finish.out" "$_as_jar")
	case "$_as_code" in
		'' | 000) echo "The api's register/finish gave no HTTP answer."; return 1 ;;
		200) ;;
		*) echo "The api's register/finish answered HTTP $_as_code."; return 1 ;;
	esac
	# Netscape cookie-jar lines are tab-separated, and the sixth field is the
	# cookie's name. Only the name is read; the value is never looked at.
	if ! awk -F '\t' '$6 == "rasputin-session" { found = 1 } END { exit !found }' "$_as_jar" 2>/dev/null; then
		echo "The api's register/finish answered 200 but issued no session cookie."; return 1
	fi
	return 0
}
