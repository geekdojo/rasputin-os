#!/bin/sh
#
# swap.sh — the same-mount swap the secrets store's start steps share:
# rasputin-store-restore.sh (geekdojo/geekdojo-brain#766),
# rasputin-store-rollback.sh (#801) and rasputin-store-migrate.sh (#1132).
# Sourced, never run. Taken out of rasputin-store-restore.sh unchanged, so
# every step moves data the same way.
#
# WHY RENAMES INSIDE ONE DIRECTORY. In openbao.service's mount namespace the
# data directory is a ReadWritePaths= bind mount: it cannot be renamed, and a
# move across it is a copy, not a rename. So each step puts its new tree in a
# work directory inside the target, and swaps entries by renames that never
# leave it.
#
#   present PATH
#       True when PATH exists, a dangling symbolic link included.
#
#   move_entries KIND FROM TO
#       Moves entries of FROM into TO by rename. KIND data moves every entry
#       but the work directories (each step's pair, .rasputin-restore-*,
#       .rasputin-rollback-* and .rasputin-migrate-*); KIND seal moves
#       seal-key and seal.hcl only. Stops at the first failure and returns 1.
#
#   roll_back KIND DIR NEW OLD PHASE
#       Undoes one directory's swap. In phase B every live entry goes back to
#       NEW, then OLD's entries go back to DIR; in phase A only OLD's go back.
#       Returns 1 at the first failed rename.
#
#   tar_aside FROM TAR
#       Writes FROM's tree to TAR: a tar of FROM's entries to TAR.partial,
#       sync, a rename to TAR, sync. Only a complete archive ever replaces
#       TAR. On any failure TAR.partial is removed and it returns 1; TAR may
#       then be the new archive (the last sync failed) or the previous one.
#
#   data_owner DIR
#       Prints DIR's numeric owner and group as UID:GID, read with ls -ldn the
#       way the at-rest audit reads them, so no id is written in a step.
#       Returns 1, printing nothing, when they cannot be read.

present() { [ -e "$1" ] || [ -L "$1" ]; }

move_entries() {
	_from=$2 _to=$3
	if [ "$1" = seal ]; then
		set -- "$_from/seal-key" "$_from/seal.hcl"
	else
		set -- "$_from"/* "$_from"/.[!.]* "$_from"/..?*
	fi
	for _p in "$@"; do
		present "$_p" || continue
		case "${_p##*/}" in
			.rasputin-restore-new|.rasputin-restore-old|.rasputin-rollback-new|.rasputin-rollback-old) continue ;;
			.rasputin-migrate-new|.rasputin-migrate-old) continue ;;
		esac
		mv -f "$_p" "$_to/" || return 1
	done
	return 0
}

roll_back() {
	if [ "$5" = B ]; then
		move_entries "$1" "$2" "$3" || return 1
	fi
	move_entries "$1" "$4" "$2"
}

tar_aside() {
	if ! { rm -f "$2.partial" && tar -cf "$2.partial" -C "$1" . && sync && mv -f "$2.partial" "$2" && sync; }; then
		# Its own error dropped on purpose: the caller reports the failure, and
		# the next tar_aside starts by removing it again.
		rm -f "$2.partial" 2>/dev/null
		return 1
	fi
	return 0
}

data_owner() {
	_do=$(ls -ldn "$1" 2>/dev/null | awk 'NR == 1 { print $3 ":" $4 }')
	case "$_do" in
		[0-9]*:[0-9]*) printf '%s\n' "$_do" ;;
		*) return 1 ;;
	esac
}
