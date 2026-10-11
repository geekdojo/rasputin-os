#!/bin/sh
#
# rasputin-seal-key.sh — create the secrets store's seal key once, on a control
# plane that has neither a key nor store data, and refuse to start the cluster
# when the store has data but no key (geekdojo/geekdojo-brain#803; ADR-0010
# S10, S12).
#
# WHY EVERY BOOT, AND NOT IN FIRSTBOOT. firstboot is run-once (guarded by
# .provisioned). A control plane that reaches this image by an OS update keeps
# its persistent partition and never runs firstboot again, and it needs a key
# too. So this runs on every boot of a control plane, and decides from what is
# on disk.
#
# THE DECISION, in this order. Each boot ends in exactly one outcome.
#   1. A key exists under any name (a file, a directory, a symlink): nothing is
#      ever written. A regular 32-byte key with a non-empty regular seal.hcl is
#      `untouched`; anything else is `failed`, the defect is named, and nothing
#      is repaired.
#   2. The store's data directory cannot be listed, or is not a directory:
#      `failed`, because nobody can tell whether store data exists. `ls -A` is
#      used and its exit status checked; a glob would read an unreadable
#      directory as empty, which fails open.
#   3. The data directory has any entry, dotfiles included: `refused`. A new
#      key cannot open existing data. No key is minted, the data directory is
#      never written (this script has no code path into it, and the unit's
#      ProtectSystem=strict makes it read-only), and the gate file below keeps
#      rasputin-api.service from starting, so the cluster does not come up.
#   4. No key and no data: `created`. 32 bytes from the kernel CSPRNG go
#      straight from the random device into a 0600 temp file; the key id is
#      rasputin-<kernel uuid>, independent of the key; the fragment is written
#      beside it; both are renamed into place with the KEY LAST. The key file is
#      the commit point: a power cut before its rename leaves no key and an
#      orphan fragment the next boot replaces, and after it a complete pair.
#
# KEY BYTES never enter a shell variable, an argument, stdout or a log. They go
# from the random device to the file. The key id is not secret.
#
# STABLE CONTRACT. Other components read what this script leaves behind. These
# are literal and do not change without changing their readers:
#
#   The key and fragment (read by openbao.service through LoadCredential=, and
#   by #828 / SST-15's bench check):
#     /var/lib/rasputin/openbao-seal/seal-key   32 bytes, 0600 root
#     /var/lib/rasputin/openbao-seal/seal.hcl   0600 root, a `seal "static"`
#                                               stanza naming the key id and
#                                               the credential path
#
#   The journal and console line, one per run (read by #828 / SST-15):
#     rasputin-seal-key: outcome=<outcome> key_id=<id|-> reason="<sentence>"
#   on stdout with a syslog priority prefix (<6> created and untouched, <3>
#   failed, <2> refused), and the same line on /dev/kmsg so it reaches the
#   serial and HDMI console. The tokens `rasputin-seal-key: outcome=created`
#   and `rasputin-seal-key: outcome=refused` are what a reader matches.
#
#   The outcome record (read by the api-side outcome reader, a separate
#   rasputin-control-plane change, geekdojo/geekdojo-brain#833):
#     /run/rasputin-seal-key/outcome   0600 root, tmpfs: it lasts for THIS BOOT
#                                      ONLY and is rewritten on every run
#   It holds exactly four lines, each KEY=VALUE, the value being everything
#   after the first "=":
#     outcome=<created|untouched|failed|refused>
#     boot_id=<the kernel's boot_id for this boot, or - if unreadable>
#     key_id=<rasputin-<uuid>, or - when no key id is known>
#     reason=<one English sentence, starting with a capital, ending with ".">
#   It is written to a temp file and renamed, so a reader never sees half of it.
#
#   The gate (read by rasputin-api.service's AssertPathExists=!):
#     /run/rasputin-seal-key/refused   exists only after a run that refused
#
# EXIT STATUS. 0 created or untouched, 1 failed, 2 refused.
#
# COLLABORATORS arrive as environment variables with production defaults, so
# the tests can point every one at a scratch tree. The unit sets none.
set -u

PERSIST="${RASPUTIN_SEALKEY_PERSIST:-/var/lib/rasputin}"
RUN="${RASPUTIN_SEALKEY_RUN:-/run/rasputin-seal-key}"
RANDOM_SRC="${RASPUTIN_SEALKEY_RANDOM:-/dev/random}"
UUID_SRC="${RASPUTIN_SEALKEY_UUID:-/proc/sys/kernel/random/uuid}"
BOOTID_SRC="${RASPUTIN_SEALKEY_BOOTID:-/proc/sys/kernel/random/boot_id}"
KMSG="${RASPUTIN_SEALKEY_KMSG:-/dev/kmsg}"

SEAL_DIR="$PERSIST/openbao-seal"
DATA_DIR="$PERSIST/openbao"
KEY="$SEAL_DIR/seal-key"
HCL="$SEAL_DIR/seal.hcl"
KEY_TMP="$SEAL_DIR/.seal-key.new"
HCL_TMP="$SEAL_DIR/.seal.hcl.new"
GATE="$RUN/refused"
RECORD="$RUN/outcome"
RECORD_TMP="$RUN/.outcome.new"
# The literal path bao reads the key from: systemd's copy of the credential.
CRED_KEY="file:///run/credentials/openbao.service/seal-key"

REFUSAL="The secrets store has data but no seal key, so this control plane will not start. A new key cannot open the existing data. Recover by restoring a backup onto a fresh install."

umask 077

# log PRIORITY LINE — stdout (the journal, where systemd turns the <N> prefix
# into PRIORITY) and /dev/kmsg (every console= device).
log() {
	printf '<%s>rasputin-seal-key: %s\n' "$1" "$2"
	printf '<%s>rasputin-seal-key: %s\n' "$1" "$2" > "$KMSG" 2>/dev/null || true
}

# finish OUTCOME KEY_ID REASON — write the record (and the gate on refusal),
# log the line, and exit with the outcome's status. Every path ends here.
finish() {
	_outcome=$1 _key_id=$2 _reason=$3
	case "$_outcome" in
		created|untouched) _prio=6 _rc=0 ;;
		refused) _prio=2 _rc=2 ;;
		*) _prio=3 _rc=1 ;;
	esac
	_boot_id=$(cat "$BOOTID_SRC" 2>/dev/null) || _boot_id=""
	[ -n "$_boot_id" ] || _boot_id=-
	if ! { rm -f "$RECORD_TMP" \
		&& printf 'outcome=%s\nboot_id=%s\nkey_id=%s\nreason=%s\n' \
			"$_outcome" "$_boot_id" "$_key_id" "$_reason" > "$RECORD_TMP" \
		&& chmod 600 "$RECORD_TMP" \
		&& mv -f "$RECORD_TMP" "$RECORD"; } 2>/dev/null; then
		rm -f "$RECORD_TMP" 2>/dev/null
		log 3 "The outcome record $RECORD could not be written, so only this journal line carries the outcome."
	fi
	if [ "$_outcome" = refused ] && ! { printf '%s\n' "$_reason" > "$GATE"; } 2>/dev/null; then
		log 3 "The gate file $GATE could not be written, so rasputin-api.service is not held back by this refusal."
	fi
	log "$_prio" "outcome=$_outcome key_id=$_key_id reason=\"$_reason\""
	exit "$_rc"
}

# fail_create REASON — a failed creation: remove every temp file, then fail.
fail_create() {
	rm -f "$KEY_TMP" "$HCL_TMP" 2>/dev/null
	finish failed - "$1"
}

# bytes FILE — the size of FILE, digits only (wc pads on some systems).
bytes() { wc -c < "$1" 2>/dev/null | tr -d ' \t'; }

# The unit's RuntimeDirectory= makes this already; by hand or in a test it may
# not exist. A run that cannot clear a stale gate still decides and logs.
mkdir -p "$RUN" 2>/dev/null
rm -f "$GATE" 2>/dev/null

# --- 1. a key is present: never write ----------------------------------------
if [ -e "$KEY" ] || [ -L "$KEY" ]; then
	if [ -L "$KEY" ]; then
		finish failed - "The seal key $KEY is a symbolic link rather than a regular file, so it was left as it is."
	fi
	if [ ! -f "$KEY" ]; then
		finish failed - "The seal key $KEY is not a regular file, so it was left as it is."
	fi
	n=$(bytes "$KEY")
	if [ "$n" != 32 ]; then
		finish failed - "The seal key $KEY is ${n:-an unreadable number of} bytes long instead of 32, so it was left as it is."
	fi
	if [ ! -e "$HCL" ] && [ ! -L "$HCL" ]; then
		finish failed - "The seal key is present but its seal configuration $HCL is missing, so neither was changed."
	fi
	if [ -L "$HCL" ] || [ ! -f "$HCL" ]; then
		finish failed - "The seal key is present but its seal configuration $HCL is not a regular file, so neither was changed."
	fi
	if [ ! -s "$HCL" ]; then
		finish failed - "The seal key is present but its seal configuration $HCL is empty, so neither was changed."
	fi
	id=$(sed -n 's/^[[:space:]]*current_key_id[[:space:]]*=[[:space:]]*"\([^"]*\)".*$/\1/p' "$HCL" 2>/dev/null | head -n 1)
	finish untouched "${id:--}" "The seal key and its seal configuration are already present, so nothing was written."
fi

# --- 2. can the store's data be read? ----------------------------------------
if [ ! -d "$DATA_DIR" ]; then
	if [ -e "$DATA_DIR" ] || [ -L "$DATA_DIR" ]; then
		finish failed - "The store's data path $DATA_DIR is not a directory, so it cannot be told whether store data exists and no key was created."
	fi
	finish failed - "The store's data directory $DATA_DIR does not exist, so it cannot be told whether store data exists and no key was created."
fi
if ! entries=$(ls -A -- "$DATA_DIR" 2>/dev/null); then
	finish failed - "The store's data directory $DATA_DIR could not be listed, so it cannot be told whether store data exists and no key was created."
fi

# --- 3. store data without a key: refuse --------------------------------------
if [ -n "$entries" ]; then
	finish refused - "$REFUSAL"
fi

# --- 4. no key, no data: create ----------------------------------------------
# Judged by what is left, not by rm's status: in a directory that cannot be
# searched rm -f fails on files that are not there, and the write below names
# that failure better.
rm -f "$KEY_TMP" "$HCL_TMP" 2>/dev/null
if [ -e "$KEY_TMP" ] || [ -e "$HCL_TMP" ]; then
	fail_create "The leftover temporary files in $SEAL_DIR could not be removed, so no key was created."
fi
# Writability first, so a directory that refuses writes is not reported as a
# random source that cannot be read. A subshell, because a failed redirection
# on a special built-in ends a non-interactive shell.
if ! (: > "$KEY_TMP") 2>/dev/null; then
	fail_create "The seal key directory $SEAL_DIR could not be written, so no key was created."
fi
if ! head -c 32 "$RANDOM_SRC" > "$KEY_TMP" 2>/dev/null; then
	fail_create "The random source $RANDOM_SRC could not be read, so no key was created."
fi
n=$(bytes "$KEY_TMP")
if [ "$n" != 32 ]; then
	fail_create "The random source $RANDOM_SRC returned ${n:-an unknown number of} bytes instead of 32, so no key was created."
fi
uuid=$(cat "$UUID_SRC" 2>/dev/null) || uuid=""
if [ -z "$uuid" ]; then
	fail_create "The kernel returned no UUID for the key id, so no key was created."
fi
case "$uuid" in
	*[!0123456789abcdef-]*) fail_create "The kernel returned a UUID with characters other than lowercase hex and hyphens, so no key was created." ;;
esac
key_id="rasputin-$uuid"
if ! printf 'seal "static" {\n  current_key_id = "%s"\n  current_key    = "%s"\n}\n' "$key_id" "$CRED_KEY" > "$HCL_TMP" 2>/dev/null; then
	fail_create "The seal configuration could not be written to $SEAL_DIR, so no key was created."
fi
if ! chmod 600 "$KEY_TMP" "$HCL_TMP" 2>/dev/null; then
	fail_create "The new seal key and configuration could not be set to mode 0600, so no key was created."
fi
sync
if ! mv -f "$HCL_TMP" "$HCL" 2>/dev/null; then
	fail_create "The new seal configuration could not be renamed into place, so no key was created."
fi
# The commit point: the key goes in last.
if ! mv -f "$KEY_TMP" "$KEY" 2>/dev/null; then
	fail_create "The new seal key could not be renamed into place, so no key was created."
fi
sync
finish created "$key_id" "A new seal key and its seal configuration were created, because there was neither a key nor store data."
