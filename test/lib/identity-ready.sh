#!/bin/sh
#
# identity-ready.sh — the smokes' check that the identity service is ready
# (geekdojo/geekdojo-brain#974, Identity 2.6). Sourced, never run, after
# test/lib/store-ready.sh, whose alerts_verdict it uses.
#
# "Ready" is a realm fact, not a unit state. keycloak.service reads `active`
# once /health/started answers, about 12 s before Keycloak imports realm
# rasputin on a first start (#975, CI job 134184702436), and the api's own
# Ready is /health/ready, which also precedes the import. So the wait ends
# when realm rasputin's discovery document answers 200 over mutual TLS with
# the api's identity client leaf. It stops at once on the facts that say it
# never will: a failed unit, or the start-hold record (#979's contract §2).
# It chooses no duration: each round's one guest call is bounded by the
# runner's own per-call timeout, and the whole wait by QEMU's existing budget,
# through ALIVE.
#
#   IR_PROBE
#       The guest command one round runs. curl prints only %{http_code}, so
#       no body and no key leaves the guest. Its one line:
#       code=<HTTP status> kc=<keycloak.service ActiveState>
#       db=<keycloak-db.service ActiveState> hold=<yes|no>
#   identity_realm_verdict LINE
#       One round's label, and its status:
#         0  ready                     code=200
#         1  waiting: ...              anything else that can still change,
#                                      a guest that did not answer included
#         2  stopped: ...              a unit failed, or the hold record exists
#   identity_realm_wait INTERVAL RUNNER ALIVE
#       Each round runs ALIVE with the fact being waited for ("realm rasputin
#       answering 200"), then RUNNER IR_PROBE (the guest runner, ssh_guest on
#       a smoke), then the verdict. ALIVE ends the caller when QEMU is gone,
#       or returns non-zero, which ends the wait. Returns 0 on ready, 1
#       otherwise. Sets IR_LAST (the last label) and IR_SECONDS (how long it
#       ran), and prints one line with the seconds when it ends.
#   identity_report_verdict CODE BODYFILE
#       alerts_verdict for "identity:" on GET /api/alerts: ready is a 200
#       array with no identity: id.

IR_PROBE='c=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 --cacert /var/lib/rasputin/trust/identity-ca.pem --cert /var/lib/rasputin/tls/identity-api-client/leaf.pem --key /var/lib/rasputin/tls/identity-api-client/leaf.key https://127.0.0.1:8543/realms/rasputin/.well-known/openid-configuration 2>/dev/null)
h=no; [ -e /run/rasputin-identity-start-hold/outcome ] && h=yes
echo "code=${c:-000} kc=$(systemctl show -P ActiveState keycloak.service) db=$(systemctl show -P ActiveState keycloak-db.service) hold=$h"'

identity_realm_verdict() {
	_ir_line=$(printf '%s\n' "$1" | tr -d '\r' | grep '^code=' | tail -1)
	if [ -z "$_ir_line" ]; then
		echo "waiting: the guest did not answer"; return 1
	fi
	_ir_code="" _ir_kc="" _ir_db="" _ir_hold=""
	for _ir_w in $_ir_line; do
		case "$_ir_w" in
			code=*) _ir_code=${_ir_w#code=} ;;
			kc=*) _ir_kc=${_ir_w#kc=} ;;
			db=*) _ir_db=${_ir_w#db=} ;;
			hold=*) _ir_hold=${_ir_w#hold=} ;;
		esac
	done
	if [ "$_ir_code" = 200 ]; then echo "ready"; return 0; fi
	if [ "$_ir_kc" = failed ]; then echo "stopped: keycloak.service is failed"; return 2; fi
	if [ "$_ir_db" = failed ]; then echo "stopped: keycloak-db.service is failed"; return 2; fi
	if [ "$_ir_hold" = yes ]; then
		echo "stopped: the start-hold record /run/rasputin-identity-start-hold/outcome exists, so keycloak.service is held"; return 2
	fi
	echo "waiting: HTTP ${_ir_code:-000}, keycloak.service ${_ir_kc:-unknown}, keycloak-db.service ${_ir_db:-unknown}"
	return 1
}

identity_realm_wait() {
	_ir_interval=$1
	_ir_runner=$2
	_ir_alive=$3
	IR_LAST=""
	_ir_start=$(date +%s)
	while :; do
		if ! "$_ir_alive" "realm rasputin answering 200"; then
			IR_LAST="stopped: QEMU is gone, so realm rasputin never answered 200"
			break
		fi
		_ir_out=$("$_ir_runner" "$IR_PROBE" 2>/dev/null)
		IR_LAST=$(identity_realm_verdict "$_ir_out")
		case $? in
			0) IR_SECONDS=$(($(date +%s) - _ir_start))
			   echo "identity realm wait: realm rasputin answered 200 after $IR_SECONDS seconds"
			   return 0 ;;
			2) break ;;
		esac
		sleep "$_ir_interval"
	done
	IR_SECONDS=$(($(date +%s) - _ir_start))
	echo "identity realm wait: ended after $IR_SECONDS seconds: $IR_LAST"
	return 1
}

identity_report_verdict() { alerts_verdict "identity:" "$1" "$2"; }
