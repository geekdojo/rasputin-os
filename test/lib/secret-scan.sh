#!/bin/sh
#
# secret-scan.sh — the exact-needle scan, the one scanner the host and the
# guest share (geekdojo/geekdojo-brain#967, F-967-02, F-967-03). Sourced,
# never run. Extracted from store-guest-checks.sh's scan (#804); it reads
# with grep -a -F -f, so binary files are searched as text and every needle
# is a fixed string, and it prints counts only, never a needle.
#
#   scan_tree ROOT NEEDLES [EXCLUDE...]
#       Every regular file under ROOT on its filesystem, but each EXCLUDE
#       path and anything under it. Prints `files=N files_exact=N`, the files
#       read and the files holding any needle.
#   scan_journal NEEDLES
#       Every boot's journal, through journalctl so compressed fields are
#       searched decompressed. Prints `journal_lines=N journal_exact=N`.
#
#   NEEDLES is a file of needles, one per line.
#
# Each returns 0 when it read something and found no needle, 1 on a hit, and
# 2 when it cannot pass because it read nothing: an empty or missing needles
# file, zero files or zero journal lines each print `INCONCLUSIVE <what>=0`.
# Its scratch files sit beside NEEDLES and are removed before it returns.
#
# Needs: find, grep, journalctl (scan_journal).

# _scan_needles NEEDLES — 0 when NEEDLES holds a needle, else the line and 2.
_scan_needles() {
	if [ ! -f "$1" ] || [ "$(grep -c . "$1" 2>/dev/null)" = 0 ]; then
		echo "INCONCLUSIVE needles=0"
		return 2
	fi
}

scan_tree() {
	_st_root=$1 _st_needles=$2
	shift 2
	_scan_needles "$_st_needles" || return 2
	_st_n=$#
	for _st_e in "$@"; do
		set -- "$@" ! -path "$_st_e" ! -path "$_st_e/*"
	done
	shift "$_st_n"
	find "$_st_root" -xdev -type f "$@" >"$_st_needles.files" 2>/dev/null
	_st_files=0 _st_x=0
	while IFS= read -r _st_f; do
		_st_files=$((_st_files + 1))
		grep -a -q -F -f "$_st_needles" "$_st_f" 2>/dev/null && _st_x=$((_st_x + 1))
	done <"$_st_needles.files"
	rm -f "$_st_needles.files"
	echo "files=$_st_files files_exact=$_st_x"
	[ "$_st_files" -gt 0 ] || { echo "INCONCLUSIVE files=0"; return 2; }
	[ "$_st_x" -eq 0 ] || return 1
	return 0
}

scan_journal() {
	_sj_needles=$1
	_scan_needles "$_sj_needles" || return 2
	journalctl --no-pager -o cat >"$_sj_needles.journal" 2>/dev/null
	_sj_lines=$(grep -a -c '' "$_sj_needles.journal")
	_sj_x=$(grep -a -c -F -f "$_sj_needles" "$_sj_needles.journal")
	rm -f "$_sj_needles.journal"
	echo "journal_lines=$_sj_lines journal_exact=$_sj_x"
	[ "$_sj_lines" -gt 0 ] || { echo "INCONCLUSIVE journal_lines=0"; return 2; }
	[ "$_sj_x" -eq 0 ] || return 1
	return 0
}
