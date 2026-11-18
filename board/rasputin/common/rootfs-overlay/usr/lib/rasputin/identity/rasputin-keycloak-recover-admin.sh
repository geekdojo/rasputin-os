#!/bin/sh
#
# rasputin-keycloak-recover-admin.sh — the identity service's admin recovery
# command (geekdojo/geekdojo-brain#1131). The api's identity.recover_admin job
# runs it, with keycloak.service stopped, to create a temporary admin client
# with `kc.sh bootstrap-admin service`.
#
#   run CLIENT_ID    As root, from the api. Starts the transient unit
#                    rasputin-keycloak-recover-admin.service with every
#                    [Service] line of keycloak.service (drop-ins included)
#                    except the lifecycle keys below, so kc.sh runs as the
#                    keycloak user with that unit's credentials, JVM variables
#                    and sandbox. The unit runs this script's `exec` mode.
#                    stdin, which carries the client secret, is passed to the
#                    unit as a file descriptor (systemd-run --pipe); kc.sh's
#                    exit status comes back through --wait.
#   exec CLIENT_ID   Inside that unit. Reads the secret, one line, from stdin
#                    and execs kc.sh with it in kc.sh's own environment only.
#
# keycloak.service is the one source of the run-as user, the credentials, the
# JVM variables and the sandbox; this script copies none of them (ARCH-DRY).
# keycloak.conf names its credentials through ${CREDENTIALS_DIRECTORY}, which
# systemd sets in both units, so one config serves both.
#
# The lifecycle keys, not carried: Type, ExecStart, ExecStartPre,
# ExecStartPost and ExecStopPost (the unit's own process and hooks),
# Restart, SuccessExitStatus and TimeoutStartSec (a one-shot run, not a
# server), and DeviceAllow (there only for the hooks).
#
# The secret never reaches argv, a file, a log line, the transient unit's
# properties or another process's environment (LOG-SECRETS): it travels on
# stdin and is exported to kc.sh alone, which names it through
# --client-secret:env.
#
# EXIT STATUS. 2 on a refusal, with one sentence on stderr. Otherwise
# systemd-run's status in `run` (kc.sh's own, through --wait) and kc.sh's in
# `exec`.
#
# COLLABORATORS arrive as environment variables with production defaults, for
# the tests: RASPUTIN_KCRECOVER_SYSTEMCTL, RASPUTIN_KCRECOVER_SYSTEMD_RUN,
# RASPUTIN_KCRECOVER_KCSH and RASPUTIN_KCRECOVER_UID. The api passes an exact
# environment and keycloak.service sets none of them.
#
# test/identity-recover-admin-test.sh tests both modes against stubs;
# test/identity-unit-functional.sh scenarios 39 and 40 run it under real
# systemd with the real Keycloak.
set -u

SYSTEMCTL="${RASPUTIN_KCRECOVER_SYSTEMCTL:-/usr/bin/systemctl}"
SYSTEMD_RUN="${RASPUTIN_KCRECOVER_SYSTEMD_RUN:-/usr/bin/systemd-run}"
KCSH="${RASPUTIN_KCRECOVER_KCSH:-/usr/lib/keycloak/bin/kc.sh}"
SELF=/usr/lib/rasputin/identity/rasputin-keycloak-recover-admin.sh
SOURCE_UNIT=keycloak.service
TRANSIENT=rasputin-keycloak-recover-admin
CONF=/etc/rasputin/identity/keycloak.conf

refuse() {
	printf '%s\n' "$1" >&2
	exit 2
}

run() {
	_client=$1
	[ -n "$_client" ] || refuse "The admin recovery was not started, because no client id was given."
	_cat=$("$SYSTEMCTL" cat "$SOURCE_UNIT" 2>/dev/null) \
		|| refuse "The admin recovery was not started, because the settings of $SOURCE_UNIT could not be read."
	set -- --quiet --pipe --wait --collect --service-type=exec "--unit=$TRANSIENT"
	_section=""
	_user=""
	while IFS= read -r _line; do
		case "$_line" in
			''|'#'*|';'*) continue ;;
			'['*) _section=$_line; continue ;;
		esac
		[ "$_section" = "[Service]" ] || continue
		case "$_line" in *=*) ;; *) continue ;; esac
		_key=${_line%%=*}
		case "$_key" in
			Type|ExecStart|ExecStartPre|ExecStartPost|ExecStopPost|Restart|SuccessExitStatus|TimeoutStartSec|DeviceAllow) continue ;;
			User) _user=${_line#*=} ;;
		esac
		set -- "$@" -p "$_line"
	done <<EOF
$_cat
EOF
	[ -n "$_user" ] \
		|| refuse "The admin recovery was not started, because $SOURCE_UNIT names no user to run it as."
	exec "$SYSTEMD_RUN" "$@" -- "$SELF" exec "$_client"
}

exec_kcsh() {
	_client=$1
	[ -n "$_client" ] || refuse "The admin recovery did not run, because no client id was given."
	[ "${RASPUTIN_KCRECOVER_UID:-$(id -u)}" != 0 ] \
		|| refuse "The admin recovery did not run, because it would have run as root."
	_secret=""
	IFS= read -r _secret || :
	[ -n "$_secret" ] || refuse "The admin recovery did not run, because no client secret arrived on its input."
	RASPUTIN_RECOVER_CLIENT_SECRET=$_secret
	export RASPUTIN_RECOVER_CLIENT_SECRET
	unset _secret
	exec "$KCSH" "--config-file=$CONF" bootstrap-admin service --optimized --no-prompt \
		--client-id "$_client" --client-secret:env RASPUTIN_RECOVER_CLIENT_SECRET
}

case "${1:-}" in
	run) run "${2:-}" ;;
	exec) exec_kcsh "${2:-}" ;;
	*) refuse "rasputin-keycloak-recover-admin.sh was run with '${1:-}' instead of run or exec, so it did nothing." ;;
esac
