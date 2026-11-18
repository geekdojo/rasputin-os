#!/bin/sh
# Static assertions on the identity service's units, keycloak-db.service and
# keycloak.service (geekdojo/geekdojo-brain#973), the OOM order across the
# control plane's units, and the units' ties to the files around them.
#
# Why. Every line of the two units is a decision with a reason recorded beside
# it, and most ways to get one wrong are silent: an order on the api deadlocks
# its restart of the identity service from inside its own start, a chosen
# restart delay or start limit is a duration someone guessed (ARCH-FACTS), a
# MemoryHigh stalls the JVM with no kill, TimeoutStartSec=infinity leaves a
# crash during start-post activating forever (F-979-11), and an [Install]
# section would let preset-all decide what post-build.sh's links decide. So each
# directive is pinned at its exact value and in its section, the forbidden ones
# are refused, and the units are tied to the static users
# package/rasputin-identity-db declares (read with real GNU make), the tmpfiles
# lines that create their directories, and the curl the start wait needs in
# both defconfigs.
#
# Negative controls. The checker is run over temp copies with one bad line
# injected each, and must refuse every one, naming it.
#
# This is a static test: it reads what ships. What systemd does with it is
# test/identity-unit-functional.sh.
#
# Run:  sh test/identity-unit-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
OVERLAY="$ROOT/board/rasputin/common/rootfs-overlay"
SYSD="$OVERLAY/etc/systemd/system"
DB_UNIT="$SYSD/keycloak-db.service"
KC_UNIT="$SYSD/keycloak.service"
API_UNIT="$SYSD/rasputin-api.service"
AGENT_UNIT="$SYSD/rasputin-agent.service"
STORE_UNIT="$SYSD/openbao.service"
TMPFILES="$OVERLAY/usr/lib/tmpfiles.d/rasputin.conf"
POSTBUILD="$ROOT/board/rasputin/common/post-build.sh"
HOOK=/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh
# Identity 2.7's hooks (geekdojo/geekdojo-brain#975).
GATE=/usr/lib/rasputin/identity/identity-db-init-gate.sh
INIT=/usr/lib/rasputin/identity/identity-db-init.sh
STAGE=/usr/lib/rasputin/identity/identity-stage-import.sh
ARMED=/usr/lib/rasputin/identity/armed.sh
MK="$ROOT/package/rasputin-identity-db/rasputin-identity-db.mk"
DEFCONFIGS="$ROOT/configs/rasputin_rpi_defconfig $ROOT/configs/rasputin_n100_defconfig"

# Fail closed: a missing input or tool is a failure with a sentence.
for f in "$DB_UNIT" "$KC_UNIT" "$API_UNIT" "$AGENT_UNIT" "$STORE_UNIT" "$TMPFILES" "$POSTBUILD" "$MK" $DEFCONFIGS; do
	[ -f "$f" ] || { echo "FAILED: the file $f is missing, so the identity units cannot be checked."; exit 1; }
done
command -v make >/dev/null 2>&1 \
	|| { echo "FAILED: GNU make is not on PATH, and the identity users are read from rasputin-identity-db.mk with it."; exit 1; }

. "$ROOT/test/lib/checks.sh"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/unit-directives.sh"
count() { printf '%s\n' "$1" | grep -c "^$2|$3=" ; }
perms() { ls -ld "$1" 2>/dev/null | cut -c1-10; }

# The static users, from the package. Each line: name uid group gid ...
USERS=$(mk_var "$MK" RASPUTIN_IDENTITY_DB_USERS) || { echo "FAILED: could not read RASPUTIN_IDENTITY_DB_USERS from $MK."; exit 1; }
user_field() { printf '%s\n' "$USERS" | awk -v n="$1" -v f="$2" '$1 == n { print $f; exit }'; }
KC_UID=$(user_field keycloak 2) KC_GID=$(user_field keycloak 4)
PG_UID=$(user_field postgres 2) PG_GID=$(user_field postgres 4)
[ -n "$KC_UID" ] && [ -n "$KC_GID" ] && [ -n "$PG_UID" ] && [ -n "$PG_GID" ] \
	|| { echo "FAILED: RASPUTIN_IDENTITY_DB_USERS ('$USERS') does not declare both the keycloak and the postgres user."; exit 1; }

V=/var/lib/rasputin
KC_APPEND='-XX:-UsePerfData -XX:ErrorFile=/dev/null -XX:-CreateCoredumpOnCrash -Djava.awt.headless=true -Djava.net.preferIPv4Stack=true -Dcom.arjuna.ats.internal.arjuna.utils.processImplementation=com.arjuna.ats.internal.arjuna.utils.UuidProcessId -XX:MaxMetaspaceSize=192m -XX:ReservedCodeCacheSize=64m -XX:MaxDirectMemorySize=16m'

# common U D — the checks both identity units share: the exactly/forbidden
# helpers, the sandbox, the forbidden directives and the ties. Sets nothing
# outside the caller's subshell.
exactly() {
	_got=$(values "$D" "$1" "$2")
	_st=1
	[ "$(count "$D" "$1" "$2")" -eq 1 ] && [ "$_got" = "$3" ] && _st=0
	check "[$1] $2=$3" "$_st" "got: $(printf '%s' "$_got" | tr '\n' '|')"
}
forbidden() {
	_hit=$(printf '%s\n' "$D" | grep -E "$2" || true)
	check "no $1" "$(yes_if [ -z "$_hit" ])" "forbidden line present: $(printf '%s' "$_hit" | tr '\n' '|')"
}
# lines SECTION KEY EXPECTED — KEY's values in SECTION are exactly EXPECTED
# (newline-separated), in that order.
lines() {
	_got=$(values "$D" "$1" "$2")
	check "[$1] exactly these $2 lines, in order: $(printf '%s' "$3" | tr '\n' '|')" \
		"$(yes_if [ "$_got" = "$3" ])" "got: $(printf '%s' "$_got" | tr '\n' '|')"
}

shared() {
	exactly Unit RequiresMountsFor "$V"
	exactly Service TimeoutStartSec 1h
	exactly Service Restart always
	exactly Service ProtectSystem strict
	exactly Service PrivateTmp yes
	exactly Service PrivateDevices yes
	exactly Service DeviceAllow '/dev/kmsg w'
	exactly Service NoNewPrivileges yes
	exactly Service CapabilityBoundingSet ''
	exactly Service LimitCORE 0
	exactly Service RestrictAddressFamilies 'AF_INET AF_UNIX'
	exactly Service IPAddressDeny any
	exactly Service IPAddressAllow localhost
	exactly Service MemorySwapMax 0
	exactly Service OOMScoreAdjust -900
	_sections=$(printf '%s\n' "$D" | cut -d'|' -f1 | sort -u | tr '\n' ' ')
	check "only [Unit] and [Service] sections" "$(yes_if [ "$_sections" = "Service Unit " ])" "got: $_sections"

	echo "  -- forbidden directives (TC-973-04)"
	forbidden "order on rasputin-api.service (Before= or After=; the api restarts this unit from its own start)" \
		'^Unit\|(Before|After)=.*rasputin-api\.service'
	forbidden "RestartSec (ARCH-FACTS: no chosen duration)" '\|RestartSec='
	forbidden "StartLimit setting (ARCH-FACTS: no chosen duration)" '\|StartLimit[A-Za-z]*='
	forbidden "MemoryHigh (it stalls with no kill)" '\|MemoryHigh='
	forbidden "TimeoutStartSec=infinity (F-979-11: a crash in start-post would activate forever)" '\|TimeoutStartSec=infinity'
	forbidden "WatchdogSec (nothing here pets a watchdog)" '\|WatchdogSec='
	forbidden "heap-dump flag (a heap dump copies the service's memory to disk)" 'HeapDump'
	_install=$(grep -nE '^[[:space:]]*\[Install\]' "$U" || true)
	check "no [Install] section (post-build.sh's link enables it, not preset-all)" "$(yes_if [ -z "$_install" ])" \
		"forbidden line present: $_install"

	echo "  -- ties (TC-973-05)"
	for p in $(values "$D" Service ReadWritePaths); do
		check "ReadWritePaths $p has a tmpfiles d line at 0700 owned by $WANT_UID:$WANT_GID" \
			"$(yes_if awk -v p="$p" -v u="$WANT_UID" -v g="$WANT_GID" \
				'$1 == "d" && $2 == p && $3 == "0700" && $4 == u && $5 == g { found = 1 } END { exit !found }' "$TMPFILES")" \
			"no 'd $p 0700 $WANT_UID $WANT_GID' line in $TMPFILES"
	done
	_sources=$(values "$D" Service LoadCredential | sed 's/^[^:]*://')
	for s in $_sources; do
		_dir=$(dirname "$s")
		check "credential source $s sits in a tmpfiles-declared 0700 root directory" \
			"$(yes_if awk -v p="$_dir" \
				'$1 == "d" && $2 == p && $3 == "0700" && $4 == "root" && $5 == "root" { found = 1 } END { exit !found }' "$TMPFILES")" \
			"no 'd $_dir 0700 root root' line in $TMPFILES"
	done
	for c in $(values "$D" Unit ConditionPathExists); do
		case "$c" in "$V/role.controlplane"|/etc/rasputin/identity/*) continue ;; esac
		check "condition $c is a LoadCredential source" "$(yes_if contains "
$c
" "
$_sources
")"
	done
}

# verify_db UNIT [TMPFILES] — keycloak-db.service (TC-973-01).
verify_db() (
	fails=0
	U=$1
	TMPFILES=${2:-$TMPFILES}
	D=$(directives "$U")
	WANT_UID=$PG_UID WANT_GID=$PG_GID
	echo "  -- directives (TC-973-01)"
	exactly Unit Description 'Rasputin identity database'
	exactly Unit After rasputin-firstboot.service
	lines Unit ConditionPathExists "$V/role.controlplane
$V/trust/identity-ca.pem
$V/tls/identity-db-server/leaf.pem
$V/tls/identity-db-server/leaf.key
/etc/rasputin/identity/postgresql.conf"
	exactly Service Type notify
	exactly Service NotifyAccess main
	exactly Service User postgres
	exactly Service Group postgres
	# TC-975-14: the gate as root, the init step in the sandbox, the gate's
	# post as root; none with `-`, so a refusal fails the start.
	lines Service ExecStartPre "+$GATE pre
$INIT
+$GATE post"
	for s in "$GATE" "$INIT"; do
		check "TC-975-14 $s ships executable in the overlay" "$(yes_if test -x "$OVERLAY$s")"
	done
	check "TC-975-14 $ARMED ships 0644 (sourced, never run)" "$(yes_if [ "$(perms "$OVERLAY$ARMED")" = -rw-r--r-- ])" \
		"got: $(perms "$OVERLAY$ARMED")"
	exactly Service ExecStart '/usr/bin/postgres -D /var/lib/rasputin/identity-db/data -c config_file=/etc/rasputin/identity/postgresql.conf'
	lines Service LoadCredential "server.pem:$V/tls/identity-db-server/leaf.pem
server.key:$V/tls/identity-db-server/leaf.key
identity-ca.pem:$V/trust/identity-ca.pem"
	exactly Service KillSignal SIGINT
	exactly Service KillMode mixed
	exactly Service ReadWritePaths "$V/identity-db"
	exactly Service MemoryMax 96M
	shared
	check "User= is RASPUTIN_IDENTITY_DB_USERS' postgres, $PG_UID:$PG_GID" \
		"$({ [ "$(user_field postgres 1)" = "$(values "$D" Service User)" ] && [ "$(user_field postgres 3)" = "$(values "$D" Service Group)" ]; } && echo 0 || echo 1)"
	[ "$fails" -eq 0 ]
)

# verify_kc UNIT [TMPFILES] — keycloak.service (TC-973-02).
verify_kc() (
	fails=0
	U=$1
	TMPFILES=${2:-$TMPFILES}
	D=$(directives "$U")
	WANT_UID=$KC_UID WANT_GID=$KC_GID
	echo "  -- directives (TC-973-02)"
	exactly Unit Description 'Rasputin identity service'
	exactly Unit After 'rasputin-firstboot.service keycloak-db.service'
	exactly Unit Requires keycloak-db.service
	lines Unit ConditionPathExists "$V/role.controlplane
$V/trust/identity-ca.pem
$V/tls/identity-server/leaf.pem
$V/tls/identity-server/leaf.key
$V/tls/identity-db-client/leaf.pem
$V/tls/identity-db-client/leaf.pk8
/etc/rasputin/identity/keycloak.conf"
	_mesh=$(values "$D" Unit ConditionPathExists | grep 'mesh-ca' || true)
	check "no condition names mesh-ca.pem (a missing mesh CA fails, never skips)" "$(yes_if [ -z "$_mesh" ])" "got: $_mesh"
	exactly Service Type exec
	exactly Service User keycloak
	exactly Service Group keycloak
	exactly Service SuccessExitStatus 143
	lines Service Environment 'JAVA_HOME=/usr/lib/temurin-jre
MALLOC_ARENA_MAX=2
"JAVA_OPTS_KC_HEAP=-Xms128m -Xmx384m"
"JAVA_OPTS_APPEND='"$KC_APPEND"'"'
	# TC-975-14: the stage step after the hold, as root, with no `-`.
	lines Service ExecStartPre "+$HOOK hold
+$STAGE"
	check "TC-975-14 $STAGE ships executable in the overlay" "$(yes_if test -x "$OVERLAY$STAGE")"
	exactly Service ExecStart '/usr/lib/keycloak/bin/kc.sh --config-file=/etc/rasputin/identity/keycloak.conf start --optimized --import-realm'
	lines Service ExecStartPost "+$HOOK wait"
	lines Service ExecStopPost "-+$HOOK exit"
	check "the hooks run a script that ships executable in the overlay ($HOOK)" "$(yes_if test -x "$OVERLAY$HOOK")"
	lines Service LoadCredential "server.pem:$V/tls/identity-server/leaf.pem
server.key:$V/tls/identity-server/leaf.key
identity-ca.pem:$V/trust/identity-ca.pem
mesh-ca.pem:$V/trust/mesh-ca.pem
db-client.pem:$V/tls/identity-db-client/leaf.pem
db-client.pk8:$V/tls/identity-db-client/leaf.pk8"
	exactly Service ReadWritePaths "$V/keycloak"
	exactly Service ProtectHome yes
	exactly Service ProtectKernelTunables yes
	exactly Service ProtectKernelModules yes
	exactly Service ProtectControlGroups yes
	exactly Service RestrictNamespaces yes
	exactly Service LockPersonality yes
	exactly Service RestrictRealtime yes
	exactly Service SystemCallArchitectures native
	exactly Service MemoryMax 832M
	shared
	check "User= is RASPUTIN_IDENTITY_DB_USERS' keycloak, $KC_UID:$KC_GID" \
		"$({ [ "$(user_field keycloak 1)" = "$(values "$D" Service User)" ] && [ "$(user_field keycloak 3)" = "$(values "$D" Service Group)" ]; } && echo 0 || echo 1)"
	[ "$fails" -eq 0 ]
)

# verify_oom STORE API AGENT DB KC — the OOM order (TC-973-03).
verify_oom() (
	fails=0
	for pair in "$1 -999" "$2 -950" "$3 -950" "$4 -900" "$5 -900"; do
		_u=${pair% *} _want=${pair##* }
		_got=$(values "$(directives "$_u")" Service OOMScoreAdjust)
		check "the OOM order (store -999, api and agent -950, identity -900): $(basename "$_u") has exactly OOMScoreAdjust=$_want" \
			"$(yes_if [ "$_got" = "$_want" ])" "got: $(printf '%s' "$_got" | tr '\n' '|')"
	done
	[ "$fails" -eq 0 ]
)

# verify_enabled POSTBUILD OVERLAY — both identity units enabled by exactly one
# physical post-build.sh line each, linking it into multi-user.target.wants,
# and by nothing in the overlay (TC-974-09). Comment lines do not count.
verify_enabled() (
	fails=0
	for u in keycloak-db.service keycloak.service; do
		# shellcheck disable=SC2016 # $TARGET_DIR is post-build.sh's, literally
		_want='ln -sf /etc/systemd/system/'"$u"' "$TARGET_DIR/etc/systemd/system/multi-user.target.wants/'"$u"'"'
		_lines=$(grep -nF "$u" "$1" | grep -v '^[0-9]*:[[:space:]]*#' || true)
		_n=0; [ -n "$_lines" ] && _n=$(printf '%s\n' "$_lines" | grep -c '')
		_body=$(printf '%s' "${_lines#*:}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
		check "TC-974-09 post-build.sh has exactly one line naming $u, its multi-user.target.wants link (got $_n)" \
			"$({ [ "$_n" -eq 1 ] && [ "$_body" = "$_want" ]; } && echo 0 || echo 1)" "lines: $(printf '%s' "$_lines" | tr '\n' '|')"
	done
	_wants=$(find "$2" -path '*.wants/keycloak*.service' 2>/dev/null)
	check "TC-974-09 no *.wants link for either identity unit in the overlay (post-build.sh enables them)" "$(yes_if [ -z "$_wants" ])" "$_wants"
	[ "$fails" -eq 0 ]
)

# verify_defconfigs FILE... — the start wait's curl, in each (TC-973-05).
verify_defconfigs() (
	fails=0
	for f in "$@"; do
		for l in BR2_PACKAGE_LIBCURL=y BR2_PACKAGE_LIBCURL_CURL=y BR2_PACKAGE_LIBCURL_OPENSSL=y \
			'# BR2_PACKAGE_LIBCURL_EXTRA_PROTOCOLS_FEATURES is not set'; do
			check "$(basename "$f") has '$l'" "$(yes_if grep -qxF "$l" "$f")"
		done
	done
	[ "$fails" -eq 0 ]
)

echo "1. the shipped keycloak-db.service"
verify_db "$DB_UNIT"; check "TC-973-01 the shipped keycloak-db.service passes every check" "$?"
echo
echo "2. the shipped keycloak.service"
verify_kc "$KC_UNIT"; check "TC-973-02 the shipped keycloak.service passes every check" "$?"
echo
echo "3. the OOM order (TC-973-03)"
verify_oom "$STORE_UNIT" "$API_UNIT" "$AGENT_UNIT" "$DB_UNIT" "$KC_UNIT"; check "TC-973-03 the four-unit OOM order holds" "$?"
# #973's diff of the api and agent units against origin/main is retired: its
# merge spent it, and Identity 2.6 changes the api unit on purpose (#974).
echo
echo "4. the start wait's curl in both defconfigs (TC-973-05, F-973-05)"
verify_defconfigs $DEFCONFIGS; check "TC-973-05 both defconfigs carry the four libcurl lines" "$?"
echo
echo "5. enabled by post-build.sh, and by nothing else (TC-974-09, F-973-12)"
verify_enabled "$POSTBUILD" "$OVERLAY"; check "TC-974-09 both identity units are enabled by one post-build.sh line each" "$?"

# --- negative controls ---------------------------------------------------------
echo
echo "6. negative controls: the checker refuses each injected line (TC-973-01 to TC-973-05)"
SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT INT TERM
# refuses FN SRC DESCRIPTION SECTION LINE NEEDLE — a copy of SRC, named as the
# shipped one, with LINE added after [SECTION] (SECTION "new": appended;
# "replace:OLD": in place of the line OLD; "tmpfiles:OLD": the unit as
# shipped and the tmpfiles copy with LINE in place of OLD), must fail FN, and
# a FAIL line must name NEEDLE.
refuses() {
	_fn=$1 _src=$2
	shift 2
	mkdir -p "$SCRATCH/c"
	_copy="$SCRATCH/c/$(basename "$_src")"
	_tmpf="$TMPFILES"
	case "$2" in
		new) { cat "$_src"; printf '%s\n' "$3"; } >"$_copy" ;;
		replace:*) awk -v o="${2#replace:}" -v l="$3" '$0 == o { print l; next } { print }' "$_src" >"$_copy" ;;
		tmpfiles:*)
			cp "$_src" "$_copy"
			_tmpf="$SCRATCH/c/rasputin.conf"
			awk -v o="${2#tmpfiles:}" -v l="$3" '$0 == o { print l; next } { print }' "$TMPFILES" >"$_tmpf"
			cmp -s "$TMPFILES" "$_tmpf" && { check "$1: the injection changed the tmpfiles copy" 1 "nothing was injected"; return; }
			;;
		*) awk -v s="[$2]" -v l="$3" '{ print } $0 == s { print l }' "$_src" >"$_copy" ;;
	esac
	case "$2" in
		tmpfiles:*) ;;
		*) cmp -s "$_src" "$_copy" && { check "$1: the injection changed the copy" 1 "nothing was injected"; return; } ;;
	esac
	_out=$("$_fn" "$_copy" "$_tmpf"); _rc=$?
	_fail_line=$(printf '%s\n' "$_out" | grep -A1 'FAIL' | grep -F -e "$4" | head -1)
	_st=1
	[ "$_rc" -ne 0 ] && [ -n "$_fail_line" ] && _st=0
	check "$1: refused, naming '$4'" "$_st" "rc=$_rc; output: $(printf '%s' "$_out" | grep -A1 FAIL | tr '\n' '|')"
	rm -f "$_copy"
}
# TC-973-04: each forbidden line, in each unit.
for spec in "verify_db $DB_UNIT" "verify_kc $KC_UNIT"; do
	fn=${spec%% *} src=${spec#* }
	n=$(basename "$src")
	refuses "$fn" "$src" "TC-973-04 $n with Before=rasputin-api.service" Unit 'Before=rasputin-api.service' 'order on rasputin-api.service'
	refuses "$fn" "$src" "TC-973-04 $n with After=rasputin-api.service" Unit 'After=rasputin-api.service' 'order on rasputin-api.service'
	refuses "$fn" "$src" "TC-973-04 $n with RestartSec=5" Service 'RestartSec=5' 'RestartSec=5'
	refuses "$fn" "$src" "TC-973-04 $n with StartLimitBurst=10" Unit 'StartLimitBurst=10' 'StartLimitBurst=10'
	refuses "$fn" "$src" "TC-973-04 $n with MemoryHigh=700M" Service 'MemoryHigh=700M' 'MemoryHigh=700M'
	refuses "$fn" "$src" "TC-973-04 $n with TimeoutStartSec=infinity" 'replace:TimeoutStartSec=1h' 'TimeoutStartSec=infinity' 'TimeoutStartSec=infinity'
	refuses "$fn" "$src" "TC-973-04 $n with an [Install] section" new '[Install]
WantedBy=multi-user.target' '[Install]'
	refuses "$fn" "$src" "TC-973-04 $n with WatchdogSec=30" Service 'WatchdogSec=30' 'WatchdogSec=30'
done
KC_APPEND_LINE="Environment=\"JAVA_OPTS_APPEND=$KC_APPEND\""
refuses verify_kc "$KC_UNIT" "TC-973-04 -XX:+HeapDumpOnOutOfMemoryError in JAVA_OPTS_APPEND" "replace:$KC_APPEND_LINE" \
	"Environment=\"JAVA_OPTS_APPEND=$KC_APPEND -XX:+HeapDumpOnOutOfMemoryError\"" 'heap-dump flag'
refuses verify_kc "$KC_UNIT" "TC-973-04 -XX:HeapDumpPath in JAVA_OPTS_APPEND" "replace:$KC_APPEND_LINE" \
	"Environment=\"JAVA_OPTS_APPEND=$KC_APPEND -XX:HeapDumpPath=/var/lib/rasputin/keycloak\"" 'heap-dump flag'
# TC-973-01: one changed value in keycloak-db.service, named.
refuses verify_db "$DB_UNIT" "TC-973-01 MemoryMax=128M" 'replace:MemoryMax=96M' 'MemoryMax=128M' '[Service] MemoryMax=96M'
refuses verify_db "$DB_UNIT" "TC-973-01 TimeoutStartSec=2h" 'replace:TimeoutStartSec=1h' 'TimeoutStartSec=2h' '[Service] TimeoutStartSec=1h'
refuses verify_db "$DB_UNIT" "TC-973-01 the config condition removed" \
	'replace:ConditionPathExists=/etc/rasputin/identity/postgresql.conf' '' 'ConditionPathExists lines'
refuses verify_db "$DB_UNIT" "TC-973-01 an extra ExecStartPre= line" Service 'ExecStartPre=/bin/true' 'ExecStartPre lines'
# TC-975-14: each wrong prefix, order or missing line on the 2.7 hooks, named.
refuses verify_db "$DB_UNIT" "TC-975-14 the gate's pre with a -+ prefix" "replace:ExecStartPre=+$GATE pre" \
	"ExecStartPre=-+$GATE pre" "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the init step with a - prefix" "replace:ExecStartPre=$INIT" \
	"ExecStartPre=-$INIT" "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the gate's post with a -+ prefix" "replace:ExecStartPre=+$GATE post" \
	"ExecStartPre=-+$GATE post" "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the gate's pre without +" "replace:ExecStartPre=+$GATE pre" \
	"ExecStartPre=$GATE pre" "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the gate's post without +" "replace:ExecStartPre=+$GATE post" \
	"ExecStartPre=$GATE post" "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the init step with +" "replace:ExecStartPre=$INIT" \
	"ExecStartPre=+$INIT" "ExecStartPre lines"
# A real swap of pre and post: both lines present, in the wrong order.
mkdir -p "$SCRATCH/s"
awk -v a="ExecStartPre=+$GATE pre" -v b="ExecStartPre=+$GATE post" \
	'$0 == a { print b; next } $0 == b { print a; next } { print }' "$DB_UNIT" >"$SCRATCH/s/keycloak-db.service"
out=$(verify_db "$SCRATCH/s/keycloak-db.service"); rc=$?
check "TC-975-14 pre and post swapped: refused, naming 'ExecStartPre lines'" \
	"$({ [ "$rc" -ne 0 ] && ! cmp -s "$DB_UNIT" "$SCRATCH/s/keycloak-db.service" \
		&& printf '%s\n' "$out" | grep -A1 FAIL | grep -qF 'ExecStartPre lines'; } && echo 0 || echo 1)" "$out"
refuses verify_db "$DB_UNIT" "TC-975-14 the init step missing" "replace:ExecStartPre=$INIT" '' "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-975-14 the gate's post missing" "replace:ExecStartPre=+$GATE post" '' "ExecStartPre lines"
refuses verify_kc "$KC_UNIT" "TC-975-14 the stage step with a -+ prefix" "replace:ExecStartPre=+$STAGE" \
	"ExecStartPre=-+$STAGE" "ExecStartPre lines"
refuses verify_kc "$KC_UNIT" "TC-975-14 the stage step without +" "replace:ExecStartPre=+$STAGE" \
	"ExecStartPre=$STAGE" "ExecStartPre lines"
refuses verify_kc "$KC_UNIT" "TC-975-14 the stage step before the hold" "replace:ExecStartPre=+$HOOK hold" \
	"ExecStartPre=+$STAGE
ExecStartPre=+$HOOK hold" "ExecStartPre lines"
refuses verify_kc "$KC_UNIT" "TC-975-14 the stage step missing" "replace:ExecStartPre=+$STAGE" '' "ExecStartPre lines"
refuses verify_db "$DB_UNIT" "TC-973-01 KillMode=control-group" 'replace:KillMode=mixed' 'KillMode=control-group' '[Service] KillMode=mixed'
# TC-973-02: one changed flag or hook prefix in keycloak.service, named.
refuses verify_kc "$KC_UNIT" "TC-973-02 -Xmx512m" 'replace:Environment="JAVA_OPTS_KC_HEAP=-Xms128m -Xmx384m"' \
	'Environment="JAVA_OPTS_KC_HEAP=-Xms128m -Xmx512m"' 'Environment lines'
refuses verify_kc "$KC_UNIT" "TC-973-02 MaxMetaspaceSize=256m" "replace:$KC_APPEND_LINE" \
	"$(printf '%s' "$KC_APPEND_LINE" | sed 's/MaxMetaspaceSize=192m/MaxMetaspaceSize=256m/')" 'Environment lines'
refuses verify_kc "$KC_UNIT" "TC-973-02 UuidProcessId removed" "replace:$KC_APPEND_LINE" \
	"$(printf '%s' "$KC_APPEND_LINE" | sed 's/ -Dcom.arjuna[^ ]*//')" 'Environment lines'
refuses verify_kc "$KC_UNIT" "TC-973-02 MemoryMax=1G" 'replace:MemoryMax=832M' 'MemoryMax=1G' '[Service] MemoryMax=832M'
refuses verify_kc "$KC_UNIT" "TC-973-02 the hold with a -+ prefix" "replace:ExecStartPre=+$HOOK hold" \
	"ExecStartPre=-+$HOOK hold" "ExecStartPre lines"
refuses verify_kc "$KC_UNIT" "TC-973-02 the wait with a -+ prefix" "replace:ExecStartPost=+$HOOK wait" \
	"ExecStartPost=-+$HOOK wait" "ExecStartPost lines"
refuses verify_kc "$KC_UNIT" "TC-973-02 the exit hook without +" "replace:ExecStopPost=-+$HOOK exit" \
	"ExecStopPost=-$HOOK exit" "ExecStopPost lines"
refuses verify_kc "$KC_UNIT" "TC-973-02 the mesh CA credential removed" \
	"replace:LoadCredential=mesh-ca.pem:$V/trust/mesh-ca.pem" '' 'LoadCredential lines'
refuses verify_kc "$KC_UNIT" "TC-973-02 a mesh CA condition" Unit "ConditionPathExists=$V/trust/mesh-ca.pem" 'no condition names mesh-ca.pem'
refuses verify_kc "$KC_UNIT" "TC-973-02 SuccessExitStatus removed" 'replace:SuccessExitStatus=143' '' '[Service] SuccessExitStatus=143'
# TC-973-05: a tie broken, named.
refuses verify_kc "$KC_UNIT" "TC-973-05 User=root" 'replace:User=keycloak' 'User=root' '[Service] User=keycloak'
refuses verify_db "$DB_UNIT" "TC-973-05 the data directory's d line at 0750" \
	'tmpfiles:d /var/lib/rasputin/identity-db                0700 992  992  -' \
	'd /var/lib/rasputin/identity-db                0750 992  992  -' "ReadWritePaths $V/identity-db has a tmpfiles d line"
refuses verify_kc "$KC_UNIT" "TC-973-05 the data directory owned by the postgres uid" \
	'tmpfiles:d /var/lib/rasputin/keycloak                   0700 991  991  -' \
	'd /var/lib/rasputin/keycloak                   0700 992  992  -' "ReadWritePaths $V/keycloak has a tmpfiles d line"
refuses verify_kc "$KC_UNIT" "TC-973-05 the db-client leaf's directory without its d line" \
	'tmpfiles:d /var/lib/rasputin/tls/identity-db-client     0700 root root -' '' \
	"credential source $V/tls/identity-db-client/leaf.pem sits in"
refuses verify_db "$DB_UNIT" "TC-973-05 a leaf condition that is not a credential source" \
	"replace:ConditionPathExists=$V/tls/identity-db-server/leaf.key" "ConditionPathExists=$V/tls/identity-db-server/other.key" \
	"condition $V/tls/identity-db-server/other.key is a LoadCredential source"
# TC-974-09: the enablement, each wrong post-build.sh or overlay refused.
mkdir -p "$SCRATCH/e"
# enabled_refuses LABEL NEEDLE POSTBUILD [OVERLAY] — verify_enabled refuses.
enabled_refuses() {
	out=$(verify_enabled "$3" "${4:-$OVERLAY}"); rc=$?
	check "$1: refused, naming '$2'" \
		"$({ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -A1 FAIL | grep -qF -- "$2"; } && echo 0 || echo 1)" "$out"
}
grep -v 'multi-user.target.wants/keycloak.service"$' "$POSTBUILD" >"$SCRATCH/e/drop"
enabled_refuses "TC-974-09 keycloak.service's link dropped" 'naming keycloak.service' "$SCRATCH/e/drop"
awk '{ print } /multi-user.target.wants\/keycloak-db.service"$/ { print }' "$POSTBUILD" >"$SCRATCH/e/double"
enabled_refuses "TC-974-09 keycloak-db.service's link doubled" 'naming keycloak-db.service' "$SCRATCH/e/double"
mkdir -p "$SCRATCH/e/overlay/etc/systemd/system/multi-user.target.wants"
ln -s /etc/systemd/system/keycloak.service "$SCRATCH/e/overlay/etc/systemd/system/multi-user.target.wants/keycloak.service"
enabled_refuses "TC-974-09 an overlay wants link for keycloak.service" 'no *.wants link' "$POSTBUILD" "$SCRATCH/e/overlay"
refuses verify_kc "$KC_UNIT" "TC-974-09 keycloak.service with an [Install] section" new '[Install]
WantedBy=multi-user.target' '[Install]'
refuses verify_db "$DB_UNIT" "TC-974-09 keycloak-db.service with an [Install] section" new '[Install]
WantedBy=multi-user.target' '[Install]'
# TC-973-03: an api unit at -900, refused naming the order.
mkdir -p "$SCRATCH/o"
sed 's/^OOMScoreAdjust=-950$/OOMScoreAdjust=-900/' "$API_UNIT" >"$SCRATCH/o/rasputin-api.service"
out=$(verify_oom "$STORE_UNIT" "$SCRATCH/o/rasputin-api.service" "$AGENT_UNIT" "$DB_UNIT" "$KC_UNIT"); rc=$?
check "TC-973-03 an api unit at -900 is refused, naming the order" \
	"$({ [ "$rc" -ne 0 ] && contains 'FAIL the OOM order' "$out" && contains 'rasputin-api.service has exactly OOMScoreAdjust=-950' "$out"; } && echo 0 || echo 1)" "$out"
# TC-973-05 (F-973-05): each libcurl line removed from a defconfig, named.
for l in BR2_PACKAGE_LIBCURL=y BR2_PACKAGE_LIBCURL_CURL=y BR2_PACKAGE_LIBCURL_OPENSSL=y \
	'# BR2_PACKAGE_LIBCURL_EXTRA_PROTOCOLS_FEATURES is not set'; do
	grep -vxF "$l" "$ROOT/configs/rasputin_rpi_defconfig" >"$SCRATCH/o/rasputin_rpi_defconfig"
	out=$(verify_defconfigs "$SCRATCH/o/rasputin_rpi_defconfig"); rc=$?
	check "TC-973-05 the rpi defconfig without '$l' is refused, naming it" \
		"$({ [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep FAIL | grep -qF "$l"; } && echo 0 || echo 1)" "$out"
done
# TC-973-05: the hook not executable.
mkdir -p "$SCRATCH/x$(dirname "$HOOK")"
cp "$OVERLAY$HOOK" "$SCRATCH/x$HOOK" && chmod 0644 "$SCRATCH/x$HOOK"
out=$(OVERLAY="$SCRATCH/x"; verify_kc "$KC_UNIT"); rc=$?
check "TC-973-05 a hook that is not executable is refused, naming it" \
	"$({ [ "$rc" -ne 0 ] && contains 'FAIL the hooks run a script that ships executable' "$out"; } && echo 0 || echo 1)" "$out"

# --- the test fails closed -------------------------------------------------------
echo
echo "7. the test fails closed"
mkdir -p "$SCRATCH/root/test/lib"
cp "$0" "$SCRATCH/root/test/identity-unit-test.sh"
cp "$ROOT/test/lib/checks.sh" "$ROOT/test/lib/mk-var.sh" "$ROOT/test/lib/unit-directives.sh" "$SCRATCH/root/test/lib/"
SH_BIN=$(command -v sh)
out=$("$SH_BIN" "$SCRATCH/root/test/identity-unit-test.sh" 2>&1); rc=$?
check "with no unit files the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no unit files the message names the missing file" "$(yes_if contains 'keycloak-db.service is missing' "$out")" "$out"
NOMAKE="$SCRATCH/nomake"
mkdir -p "$NOMAKE"
ln -s "$(command -v dirname)" "$NOMAKE/dirname"
out=$(PATH="$NOMAKE" "$SH_BIN" "$0" 2>&1); rc=$?
check "with no make the test exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit=$rc"
check "with no make the message names GNU make" "$(yes_if contains 'GNU make is not on PATH' "$out")" "$out"

echo
if [ "$fails" -ne 0 ]; then echo "identity-unit-test: $fails check(s) FAILED"; exit 1; fi
echo "identity-unit-test: all checks passed"
