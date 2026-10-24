#!/bin/sh
#
# swap.sh — the same-mount swap the secrets store's start steps share:
# rasputin-store-restore.sh (geekdojo/geekdojo-brain#766) and
# rasputin-store-rollback.sh (#801). Sourced, never run. Taken out of
# rasputin-store-restore.sh unchanged, so both steps move data the same way.
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
#       but the work directories (both steps' pairs, .rasputin-restore-* and
#       .rasputin-rollback-*); KIND seal moves seal-key and seal.hcl only.
#       Stops at the first failure and returns 1.
#
#   roll_back KIND DIR NEW OLD PHASE
#       Undoes one directory's swap. In phase B every live entry goes back to
#       NEW, then OLD's entries go back to DIR; in phase A only OLD's go back.
#       Returns 1 at the first failed rename.

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
