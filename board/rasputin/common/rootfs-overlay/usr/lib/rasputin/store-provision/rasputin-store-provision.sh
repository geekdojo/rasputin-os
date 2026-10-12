#!/bin/sh
#
# rasputin-store-provision.sh — add the kv-v2 mounts and cert roles a later
# release lists to a secrets store an earlier release initialised, with no
# root token (geekdojo/geekdojo-brain#805; ADR-0010 S9).
#
# WHY. The store initialises itself once, from init.json, and init.json is
# frozen from the store-arming release on: a store keeps what its first start
# made. A later release's new mounts and roles come from provision.tsv, added
# by the store's one fixed provisioner identity, rasputin-provisioner. Its
# policy can add mounts and roles inside one namespace, rasputin-rel-*, and
# bind those roles only to the pre-shipped rasputin-bindable policy. It
# authors no policy and changes no fixed mount, role or policy.
#
# PHASES, in rasputin-store-provision.service's order. The unit is pulled in
# by openbao.service's start, needs it active (Requisite=) and is stopped with
# it (PartOf=), so it runs once per run of the store, and holds
# rasputin-api.service (Before=) until it exits.
#   pre      ExecStartPre=-+   root. Makes the record directory, removes a
#            stale result, writes the pending marker.
#   wait     ExecStartPre=+    root, because it reads the system journal. With
#            no items it exits 0 at once. Otherwise it waits for THIS run of
#            the store to report its unseal, and fails the start (so apply
#            never runs) when the store reports it did not unseal.
#   apply    ExecStart=        the store's user. Logs in as the provisioner
#            and adds what is missing. Nothing it finds present is changed.
#   record   ExecStartPost=-+  root. The record and the outcome line.
#   stopped  ExecStopPost=-+   root. A run that ended before record ran (a
#            failed wait or apply, the store stopping) is recorded failed, and
#            so is one that never started (an absent certificate: no pending
#            marker, and a result other than success).
#
# THE WAIT ENDS ON FACTS. bao logs each stored-key unseal attempt's result on
# its journal stream (capability row T53). The wait follows this run's lines
# only, identified by the store unit's InvocationID, from the start of the run
# (a line logged before the wait began is replayed), and ends on the first
# decisive one:
#   success   "unsealed with stored key";
#   failure   any "failed to unseal core" line except the self-init
#             "none were found: is the server initialized?" one, which passes
#             while an empty store initialises; and "vault still sealed after
#             using stored unseal key", "error unsealing core" and "failed to
#             automatically unseal after initialization". A static seal's
#             check is deterministic, so one such line is final.
# The store being stopped or restarted ends it too: PartOf= stops this unit.
# A store that crashes into its start limit mid-wait does not (no requirement
# dependency, which would cut the store's crash loop short); the bound below
# ends that wait.
# One case reports nothing: a bao that hangs before logging any result. It
# sends no notify after READY, and sys/health cannot tell "not attempted" from
# "failed". For that case alone the wait stops after RASPUTIN_STOREPROV_
# UNSEAL_BOUND seconds (10: two of bao's fixed 5 s retry intervals) with no
# decisive line, under rasputin-os EXCEPTIONS.md EX-1 (D-805-C). When it does,
# it asks sys/health once, and a 200 then is success: journald may have
# dropped the success line under its rate limit. Nothing polls on an interval.
#
# THE API'S WORST-CASE HOLD. With no items, none. With N items: at most 10 s
# for the wait, 2 s for its one health ask, and then one login and at most two
# calls per item, each bounded by BAO_CLIENT_TIMEOUT=2s with no retry:
# 10 + 2 + 2 x (1 + 2N) seconds, 22 s for N = 2. On a healthy store it is the
# unseal itself plus loopback calls in milliseconds.
#
# STABLE CONTRACT. Readers depend on these; they do not change without them:
#
#   The journal and console line, one per recorded outcome (read by the bench
#   skill, and by test/boot-smoke.sh from the serial console):
#     rasputin-store-provision: outcome=<applied|unchanged|failed> changed=<n> reason="<sentence>"
#   on stdout with a syslog priority prefix (<6> applied and unchanged, <3>
#   failed), and the same line on /dev/kmsg.
#
#   The outcome record (read by the api's outcome reader, #833):
#     /run/rasputin-store-provision/outcome   0600 root, tmpfs: THIS BOOT ONLY
#   exactly four lines, each KEY=VALUE, the value everything after the first =:
#     outcome=<applied|unchanged|failed>
#     boot_id=<the kernel's boot_id, or - if unreadable>
#     run_id=<this run's INVOCATION_ID, or - if unset>
#     reason=<one English sentence, starting with a capital, ending with ".">
#   written to a temp file and renamed, and replaced on each run.
#   `systemctl start rasputin-store-provision.service` returns once the run
#   in flight has finished.
#
#   provision.tsv, one tab-separated item per line; # comments and blank
#   lines are skipped:
#     mount <name>            a kv-v2 mount at <name>
#     role <name> <policy>    a cert role <name> trusting the store CA,
#                             admitting only the CommonName <name>, binding
#                             only <policy>, token_no_default_policy, 1h ttl
#   <name> matches ^rasputin-rel-[a-z0-9-]+$ and <policy> is rasputin-bindable.
#   Anything else refuses the whole file before any store call.
#
# NEVER LOGGED: a token. It lives in BAO_TOKEN in apply's environment only.
# A journal line quoted in a reason is cut to bao's error field.
#
# EXIT STATUS. pre, record and stopped: 0 (their unit lines carry `-`). wait
# and apply: 0, or 1 on a failure, which fails the start. 2: an unknown phase.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u
LC_ALL=C
export LC_ALL

RUN="${RASPUTIN_STOREPROV_RUN:-/run/rasputin-store-provision}"
WORK="${RASPUTIN_STOREPROV_WORK:-/run/rasputin-store-provision-work}"
CONFIG="${RASPUTIN_STOREPROV_CONFIG:-/etc/rasputin/openbao/provision.tsv}"
CREDS="${RASPUTIN_STOREPROV_CREDS:-/run/credentials/rasputin-store-provision.service}"
BAO="${RASPUTIN_STOREPROV_BAO:-/usr/bin/bao}"
JOURNAL="${RASPUTIN_STOREPROV_JOURNAL:-journalctl}"
STOREUNIT="${RASPUTIN_STOREPROV_STOREUNIT:-openbao.service}"
BOOTID_SRC="${RASPUTIN_STOREPROV_BOOTID:-/proc/sys/kernel/random/boot_id}"
BOUND="${RASPUTIN_STOREPROV_UNSEAL_BOUND:-10}"
PENDING="$RUN/pending"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"
RESULT="$WORK/result"
NS=rasputin-rel-
BINDABLE=rasputin-bindable
NOT_ADDED="so this release's mounts and roles were not added."

# The store client: the listener in openbao.hcl, the store CA and the
# provisioner's leaf from this unit's credentials, one bounded try per call.
BAO_ADDR=https://127.0.0.1:8200
BAO_CACERT="$CREDS/store-ca.pem"
BAO_CLIENT_CERT="$CREDS/provisioner.pem"
BAO_CLIENT_KEY="$CREDS/provisioner.key"
BAO_CLIENT_TIMEOUT=2s
BAO_MAX_RETRIES=0
export BAO_ADDR BAO_CACERT BAO_CLIENT_CERT BAO_CLIENT_KEY BAO_CLIENT_TIMEOUT BAO_MAX_RETRIES

umask 077

# Both read by outcome.sh.
# shellcheck disable=SC2034
OUTCOME_TAG=rasputin-store-provision
# shellcheck disable=SC2034
OUTCOME_KMSG="${RASPUTIN_STOREPROV_KMSG:-/dev/kmsg}"
. "$(dirname "$0")/../outcome/outcome.sh"

# result OUTCOME CHANGED REASON — the work directory's result, for record and
# stopped. A write that fails is said on stderr (the journal); stopped then
# records the run failed without its reason.
result() {
	if ! { rm -f "$RESULT" && printf 'outcome=%s\nchanged=%s\nreason=%s\n' "$1" "$2" "$3" > "$RESULT"; } 2>/dev/null; then
		printf '<4>%s: The result could not be written to %s.\n' "$OUTCOME_TAG" "$RESULT" >&2
	fi
}

# fail REASON — a failed wait or apply: the result, then exit 1.
fail() {
	result failed 0 "$1"
	exit 1
}

# result_field KEY — KEY's value in the work directory's result, or nothing.
result_field() { sed -n "s/^$1=//p" "$RESULT" 2>/dev/null | sed -n 1p; }

# clean TEXT — one line, no control character and no quote or backslash, at
# most 240 characters: safe inside reason="...".
clean() { printf '%s' "$1" | tr -d '\000-\037\177"\\' | cut -c1-240; }

# http_code FILE — the HTTP status bao's error output in FILE names, or
# "no answer".
http_code() {
	_hc=$(sed -n 's/.*Code: \([0-9][0-9][0-9]\).*/\1/p' "$1" 2>/dev/null | sed -n 1p)
	if [ -n "$_hc" ]; then printf 'HTTP %s' "$_hc"; else printf 'no answer'; fi
}

# valid_name NAME — NAME matches ^rasputin-rel-[a-z0-9-]+$.
valid_name() {
	case "$1" in "$NS"*) ;; *) return 1 ;; esac
	_vn=${1#"$NS"}
	[ -n "$_vn" ] || return 1
	case "$_vn" in *[!a-z0-9-]*) return 1 ;; esac
	return 0
}

# parse — read provision.tsv into MOUNTS and ROLES (one name per line) and
# ITEMS (their count). Every refusal is a failed result naming the line or
# the file, and exit 1, before any store call.
parse() {
	MOUNTS="" ROLES="" ITEMS=0
	[ -f "$CONFIG" ] && [ -r "$CONFIG" ] \
		|| fail "The provisioning file $CONFIG is missing or unreadable, $NOT_ADDED"
	_tab=$(printf '\t')
	_n=0 _seen=""
	# The file is read once, into the shell, so a read error is the cat's.
	_text=$(cat -- "$CONFIG" 2>/dev/null) \
		|| fail "The provisioning file $CONFIG could not be read, $NOT_ADDED"
	while IFS= read -r _line || [ -n "$_line" ]; do
		_n=$((_n + 1))
		case "$_line" in ''|'#'*) continue ;; esac
		case "$_line" in *[!"$_tab"' ']*) ;; *) continue ;; esac
		_f1=${_line%%"$_tab"*}
		_rest=""
		case "$_line" in *"$_tab"*) _rest=${_line#*"$_tab"} ;; esac
		_f2=${_rest%%"$_tab"*}
		_f3=""
		case "$_rest" in *"$_tab"*) _f3=${_rest#*"$_tab"} ;; esac
		case "$_f1" in
			mount)
				[ -n "$_rest" ] && [ "$_rest" = "$_f2" ] \
					|| fail "Line $_n of $CONFIG is a mount with the wrong number of fields (want: mount, a name), $NOT_ADDED"
				;;
			role)
				[ -n "$_f2" ] && [ -n "$_f3" ] && [ "$_f3" = "${_f3%%"$_tab"*}" ] \
					|| fail "Line $_n of $CONFIG is a role with the wrong number of fields (want: role, a name, a policy), $NOT_ADDED"
				[ "$_f3" = "$BINDABLE" ] \
					|| fail "Line $_n of $CONFIG binds a policy other than $BINDABLE, the only one a provisioned role may bind, $NOT_ADDED"
				;;
			*) fail "Line $_n of $CONFIG has an unknown kind (want mount or role), $NOT_ADDED" ;;
		esac
		valid_name "$_f2" \
			|| fail "Line $_n of $CONFIG names something outside ${NS}<lowercase letters, digits and hyphens>, $NOT_ADDED"
		case "$_seen" in *"|$_f1 $_f2|"*)
			fail "Line $_n of $CONFIG repeats the $_f1 $_f2, $NOT_ADDED" ;;
		esac
		_seen="$_seen|$_f1 $_f2|"
		if [ "$_f1" = mount ]; then MOUNTS="$MOUNTS$_f2
"; else ROLES="$ROLES$_f2
"; fi
		ITEMS=$((ITEMS + 1))
	done <<EOF_CONFIG
$_text
EOF_CONFIG
}

# classify LINE — the decision a journal line of the store's run carries:
# prints "ok", or "fail <bao's error text>", or nothing.
classify() {
	case "$1" in
		*"failed to unseal core"*)
			case "$1" in *"none were found: is the server initialized?"*) return 0 ;; esac
			;;
		*"vault still sealed after using stored unseal key"*|*"error unsealing core"*|*"failed to automatically unseal after initialization"*) ;;
		*"unsealed with stored key"*) echo ok; return 0 ;;
		*) return 0 ;;
	esac
	# bao's error field (error="..." or err="..."), else the line from its
	# message on: never more than that line said.
	_cl=$(printf '%s\n' "$1" | sed -n 's/.*[ :]err\(or\)\{0,1\}="\(.*\)"[[:space:]]*$/\2/p')
	if [ -z "$_cl" ]; then
		for _m in "failed to unseal core" "vault still sealed after using stored unseal key" \
			"error unsealing core" "failed to automatically unseal after initialization"; do
			case "$1" in *"$_m"*) _cl="$_m${1#*"$_m"}"; break ;; esac
		done
	fi
	echo "fail $(clean "$_cl")"
}

# The wait's writers and fifo, so a decision, a signal or an exit removes
# every one of them.
JPID="" SPID="" WDIR=""
wait_cleanup() {
	for _p in $JPID $SPID; do kill "$_p" 2>/dev/null; done
	for _p in $JPID $SPID; do wait "$_p" 2>/dev/null; done
	JPID="" SPID=""
	exec 3<&- 2>/dev/null
	[ -n "$WDIR" ] && rm -rf "$WDIR"
	WDIR=""
}

phase_wait() {
	parse
	[ "$ITEMS" -gt 0 ] || exit 0
	case "$BOUND" in ''|*[!0-9]*|0) fail "The unseal bound '$(clean "$BOUND")' is not a whole number of seconds, $NOT_ADDED" ;; esac
	_id=$(systemctl show -p InvocationID --value "$STOREUNIT" 2>/dev/null)
	case "$_id" in *[!0-9a-f]*|'') _id=x ;; esac
	[ "${#_id}" -eq 32 ] \
		|| fail "The secrets store's current run could not be identified (systemd gave $STOREUNIT no InvocationID), so its unseal was not waited for and this release's mounts and roles were not added."
	trap 'wait_cleanup; exit 1' HUP INT TERM
	if ! WDIR=$(mktemp -d "$WORK/.wait.XXXXXX" 2>/dev/null) || ! mkfifo "$WDIR/f" 2>/dev/null; then
		wait_cleanup
		fail "The wait for the secrets store's unseal could not be set up in $WORK, $NOT_ADDED"
	fi
	# (a) This run's journal lines: the earlier ones replayed, then followed.
	"$JOURNAL" --follow --no-tail -o cat "_SYSTEMD_INVOCATION_ID=$_id" > "$WDIR/f" 2>/dev/null &
	JPID=$!
	# (c) The bound, for a bao that logs no result. A TERM ends its sleep.
	( trap 'kill $! 2>/dev/null; exit 0' TERM; sleep "$BOUND" & wait $!; echo @bound ) > "$WDIR/f" 2>/dev/null &
	SPID=$!
	exec 3< "$WDIR/f"
	_decision=""
	while :; do
		if ! IFS= read -r _l <&3; then _decision=bound; break; fi
		if [ "$_l" = @bound ]; then _decision=bound; break; fi
		_c=$(classify "$_l")
		case "$_c" in
			ok) _decision=ok; break ;;
			fail\ *) _decision=$_c; break ;;
		esac
	done
	wait_cleanup
	trap - HUP INT TERM
	case "$_decision" in
		ok) exit 0 ;;
		fail\ *) fail "The secrets store did not unseal (it logged: ${_decision#fail }), $NOT_ADDED" ;;
	esac
	# (b) The bound: one sys/health ask. A 200 is success.
	"$BAO" read sys/health >/dev/null 2>&1 && exit 0
	fail "The secrets store logged no unseal result within $BOUND s and did not answer its health check as unsealed, $NOT_ADDED"
}

phase_apply() {
	parse
	if [ "$ITEMS" -eq 0 ]; then
		result unchanged 0 "This release lists nothing to add to the secrets store."
		exit 0
	fi
	_err="$WORK/.err"
	BAO_TOKEN=$("$BAO" login -method=cert -token-only -no-store name=rasputin-provisioner 2>"$_err") && [ -n "$BAO_TOKEN" ] \
		|| { BAO_TOKEN=""; _w=$(http_code "$_err"); rm -f "$_err"; fail "The provisioner could not log in to the secrets store ($_w), $NOT_ADDED"; }
	export BAO_TOKEN
	_changed=0
	for _m in $MOUNTS; do
		if "$BAO" read "sys/mounts/$_m" >/dev/null 2>"$_err"; then continue; fi
		if ! grep -q 'No secret engine mount at' "$_err" 2>/dev/null; then
			_w=$(http_code "$_err"); rm -f "$_err"
			fail "The secrets store did not say whether the mount $_m exists ($_w), $NOT_ADDED"
		fi
		"$BAO" write "sys/mounts/$_m" type=kv-v2 >/dev/null 2>"$_err" \
			|| { _w=$(http_code "$_err"); rm -f "$_err"; fail "The secrets store refused the provisioner's write to sys/mounts/$_m ($_w), $NOT_ADDED"; }
		_changed=$((_changed + 1))
		printf '<6>%s: added the kv-v2 mount %s.\n' "$OUTCOME_TAG" "$_m"
	done
	if [ -n "$ROLES" ]; then
		_list=$("$BAO" list auth/cert/certs 2>"$_err") \
			|| { _w=$(http_code "$_err"); rm -f "$_err"; fail "The secrets store did not list its cert roles to the provisioner ($_w), $NOT_ADDED"; }
		for _r in $ROLES; do
			if printf '%s\n' "$_list" | grep -qxF -- "$_r"; then continue; fi
			"$BAO" write "auth/cert/certs/$_r" "certificate=@$CREDS/store-ca.pem" "allowed_common_names=$_r" \
				"token_policies=$BINDABLE" token_no_default_policy=true token_ttl=1h >/dev/null 2>"$_err" \
				|| { _w=$(http_code "$_err"); rm -f "$_err"; fail "The secrets store refused the provisioner's write to auth/cert/certs/$_r ($_w), $NOT_ADDED"; }
			_changed=$((_changed + 1))
			printf '<6>%s: added the cert role %s, bound to %s.\n' "$OUTCOME_TAG" "$_r" "$BINDABLE"
		done
	fi
	rm -f "$_err"
	BAO_TOKEN=""
	if [ "$_changed" -eq 0 ]; then
		result unchanged 0 "Every mount and role this release lists was already in the secrets store."
	else
		result applied "$_changed" "The provisioner added this release's missing mounts and roles to the secrets store."
	fi
	exit 0
}

# record OUTCOME CHANGED PRIORITY REASON — the record, the marker cleared, the
# line logged. A failed record write is logged by outcome_record; the line
# still goes out.
record() {
	# umask 077: a directory this makes is 0700.
	mkdir -p "$RUN" 2>/dev/null
	outcome_record "$RECORD" "$RECORD_TMP" "outcome=$1" \
		"boot_id=$(outcome_boot_id "$BOOTID_SRC")" "run_id=${INVOCATION_ID:--}" "reason=$4" || :
	if ! rm -f "$PENDING" 2>/dev/null || [ -e "$PENDING" ]; then
		outcome_log 4 "The marker $PENDING could not be removed, so a later stop may record a second outcome for this run."
	fi
	outcome_log "$3" "outcome=$1 changed=$2 reason=\"$4\""
}

case "${1:-}" in
	pre)
		# The record directory, 0700 by the umask. No RuntimeDirectory= makes
		# it: the unit's one is the store user's work directory.
		mkdir -p "$RUN" 2>/dev/null
		rm -f "$RESULT" 2>/dev/null
		if ! (: > "$PENDING") 2>/dev/null; then
			outcome_log 4 "The marker $PENDING could not be written, so a run that ends early may not be recorded."
		fi
		;;
	wait) phase_wait ;;
	apply) phase_apply ;;
	record)
		_o=$(result_field outcome) _c=$(result_field changed) _r=$(result_field reason)
		case "$_o" in
			applied|unchanged) record "$_o" "${_c:-0}" 6 "$_r" ;;
			failed) record failed 0 3 "$_r" ;;
			*) record failed 0 3 "The provisioner's run left no result, so whether this release's mounts and roles were added is not known." ;;
		esac
		;;
	stopped)
		rm -rf "$WORK"/.wait.* 2>/dev/null
		_res=${SERVICE_RESULT:-unknown} _st=${EXIT_STATUS:-unknown}
		_why="service result $_res, exit status $_st"
		if [ ! -e "$PENDING" ]; then
			[ "$_res" = success ] && exit 0
			# The run failed before pre ran: systemd could not spawn it. While the
			# store runs, its CA is there (the store's own condition), so the one
			# credential that can be missing is the provisioner's leaf: systemd's
			# step CREDENTIALS, status 243. EXIT_STATUS cannot say so, because it
			# describes the main process and is unset when a control process fails
			# (measured, systemd 258.7). Any result here is a stale one.
			record failed 0 3 "The provisioner's certificate could not be loaded ($_why), $NOT_ADDED"
			exit 0
		fi
		_r=$(result_field reason)
		if [ -n "$_r" ]; then
			record failed 0 3 "${_r%.} ($_why)."
		else
			record failed 0 3 "The provisioner's run ended before it finished ($_why): the secrets store stopped or the run was stopped, $NOT_ADDED"
		fi
		;;
	*)
		outcome_log 3 "rasputin-store-provision.sh was run with '$(clean "${1:-}")' instead of pre, wait, apply, record or stopped, so nothing was done."
		exit 2
		;;
esac
exit 0
