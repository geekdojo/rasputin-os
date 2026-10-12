#!/bin/sh
#
# unit-directives.sh — read a systemd unit file as one line per directive.
# Sourced, never run (geekdojo/geekdojo-brain#757, F-757-05). The static unit
# tests share it: test/store-unit-test.sh, test/seal-key-test.sh and
# test/api-store-wiring-test.sh.
#
#   directives UNIT
#       Prints one "Section|Key=Value" line per directive in UNIT: comments
#       and blank lines dropped, surrounding whitespace trimmed, the section
#       the directive sits in before the bar.
#
#   values D SECTION KEY
#       Prints every value KEY has in SECTION of D, one per line, where D is
#       the output of directives.
#
#   words D SECTION KEY
#       Prints the whitespace-separated words of every KEY in SECTION of D,
#       one per line.

directives() {
	awk '
		{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
		/^$/ || /^[#;]/ { next }
		/^\[.*\]$/ { sect = substr($0, 2, length($0) - 2); next }
		{ print sect "|" $0 }
	' "$1"
}

values() { printf '%s\n' "$1" | sed -n "s/^$2|$3=//p"; }

words() { values "$1" "$2" "$3" | tr ' \t' '\n\n' | sed '/^$/d'; }
