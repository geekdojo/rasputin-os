#!/bin/sh
#
# hcl-keys.sh — read keys out of a flat HCL file such as the secrets store's
# openbao.hcl. Sourced, never run (geekdojo/geekdojo-brain#756, F-756-03,
# F-756-09). The one reader of that file's keys: test/store-config-test.sh and
# test/api-store-wiring-test.sh both use it, and neither parses HCL itself.
#
#   hcl_get FILE BLOCK KEY
#       Prints KEY's value in BLOCK, without its quotes, and returns 0. BLOCK
#       is a block header as written, words separated by one space (for
#       example 'listener "tcp"'), or empty for the top level. Exactly one
#       KEY in that scope, or it returns non-zero.
#   hcl_keys FILE BLOCK
#       Prints the keys and the block headers in BLOCK (empty: the top level),
#       one per line, in file order. A header is printed with " {" after it
#       (listener "tcp" {), so a block is never mistaken for a key. A key that
#       occurs twice is printed twice.
#
# A SCOPE. Every block with the same header is one scope: a key in two
# `listener "tcp"` blocks counts twice in 'listener "tcp"', so hcl_get refuses
# it and hcl_keys prints it twice. A nested block is a scope of its own, named
# "OUTER / INNER", and is printed as a header in its parent.
#
# WHAT IT READS. One construct per line: `key = value`, `header {` and `}`.
# Blank lines and #, // comments are skipped, and so is a trailing comment
# after a value. A value is a double-quoted string (no escaped quotes) or a
# bare word such as true. Anything else (a /* comment, a block opened and
# closed on one line, a list spanning lines, an unclosed block) is refused
# rather than guessed at.
#
# FAILS CLOSED. A missing file, a line it cannot read, a missing KEY or BLOCK,
# and (for hcl_get) a KEY that occurs more than once each print NOTHING on
# stdout, write a sentence naming the file or the key to stderr, and return
# non-zero. A caller that compares the output can never pass on an empty read.

# _hcl_scan FILE — one "SCOPE<TAB>k<TAB>KEY<TAB>VALUE" or
# "SCOPE<TAB>b<TAB>HEADER<TAB>" line per entry; SCOPE is empty at the top.
_hcl_scan() {
	if [ ! -f "$1" ]; then
		echo "Could not read $1. The file does not exist." >&2
		return 1
	fi
	awk -v F="$1" '
		function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
		function bad(why) { printf "Could not read %s. Line %d %s: %s\n", F, NR, why, t > "/dev/stderr"; err = 1; exit 1 }
		BEGIN { depth = 0; scope[0] = "" }
		{
			t = trim($0)
			if (t == "" || t ~ /^#/ || t ~ /^\/\//) next
			if (t ~ /^\/\*/) bad("opens a /* comment, which this reader does not parse")
			if (t == "}") {
				if (depth == 0) bad("closes a block that was never opened")
				depth--
				next
			}
			if (t ~ /\{$/) {
				h = trim(substr(t, 1, length(t) - 1))
				if (h !~ /^[A-Za-z_][A-Za-z0-9_-]*([ \t]+"[^"]*")*$/) bad("is not a block header this reader parses")
				gsub(/[ \t]+/, " ", h)
				printf "%s\tb\t%s\t\n", scope[depth], h
				depth++
				opened[depth] = NR; opener[depth] = t
				scope[depth] = (depth == 1) ? h : scope[depth - 1] " / " h
				next
			}
			if (t ~ /^[A-Za-z_][A-Za-z0-9_-]*[ \t]*=/) {
				k = t; sub(/[ \t]*=.*$/, "", k)
				v = t; sub(/^[^=]*=[ \t]*/, "", v)
				if (substr(v, 1, 1) == "\"") {
					rest = substr(v, 2)
					i = index(rest, "\"")
					if (i == 0) bad("has a string with no closing quote")
					val = substr(rest, 1, i - 1)
					after = trim(substr(rest, i + 1))
				} else {
					val = v
					sub(/[ \t]*(#|\/\/).*$/, "", val)
					val = trim(val)
					after = ""
					if (val == "" || val ~ /[ \t{}\[\]"]/) bad("has a value this reader does not parse")
				}
				if (after != "" && after !~ /^(#|\/\/)/) bad("has text after its value")
				printf "%s\tk\t%s\t%s\n", scope[depth], k, val
				next
			}
			bad("is not a key, a block header or a closing brace")
		}
		END {
			if (!err && depth != 0) { printf "Could not read %s. Line %d opens a block that the file never closes: %s\n", F, opened[depth], opener[depth] > "/dev/stderr"; exit 1 }
		}
	' "$1"
}

# _hcl_where BLOCK — the scope, in words, for a message.
_hcl_where() {
	if [ -z "$1" ]; then echo "at the top level"; else echo "in the $1 block"; fi
}

hcl_get() {
	_hg_file=${1:-} _hg_block=${2:-} _hg_key=${3:-}
	if [ -z "$_hg_file" ] || [ -z "$_hg_key" ]; then
		echo "The hcl_get helper needs a file, a block (empty for the top level) and a key." >&2
		return 2
	fi
	_hg_scan=$(_hcl_scan "$_hg_file") || return 1
	_hg_n=$(printf '%s\n' "$_hg_scan" | awk -F'\t' -v b="$_hg_block" -v k="$_hg_key" \
		'$1 == b && $2 == "k" && $3 == k { n++ } END { print n + 0 }')
	if [ "$_hg_n" -eq 0 ]; then
		echo "$_hg_file has no $_hg_key $(_hcl_where "$_hg_block")." >&2
		return 1
	fi
	if [ "$_hg_n" -gt 1 ]; then
		echo "$_hg_file has $_hg_key $_hg_n times $(_hcl_where "$_hg_block"), and exactly one is allowed." >&2
		return 1
	fi
	printf '%s\n' "$_hg_scan" | awk -F'\t' -v b="$_hg_block" -v k="$_hg_key" \
		'$1 == b && $2 == "k" && $3 == k { print $4 }'
}

hcl_keys() {
	_hk_file=${1:-} _hk_block=${2:-}
	if [ -z "$_hk_file" ]; then
		echo "The hcl_keys helper needs a file and a block (empty for the top level)." >&2
		return 2
	fi
	_hk_scan=$(_hcl_scan "$_hk_file") || return 1
	if [ -n "$_hk_block" ]; then
		# The block's header, wherever its parent is: the scope's last part.
		_hk_parent=${_hk_block% / *}
		[ "$_hk_parent" = "$_hk_block" ] && _hk_parent=""
		_hk_head=${_hk_block##* / }
		_hk_n=$(printf '%s\n' "$_hk_scan" | awk -F'\t' -v p="$_hk_parent" -v h="$_hk_head" \
			'$1 == p && $2 == "b" && $3 == h { n++ } END { print n + 0 }')
		if [ "$_hk_n" -eq 0 ]; then
			echo "$_hk_file has no $_hk_block block." >&2
			return 1
		fi
	fi
	printf '%s\n' "$_hk_scan" | awk -F'\t' -v b="$_hk_block" \
		'$1 == b && $2 == "k" { print $3 } $1 == b && $2 == "b" { print $3 " {" }'
}
