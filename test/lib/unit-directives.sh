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

directives() {
	awk '
		{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
		/^$/ || /^[#;]/ { next }
		/^\[.*\]$/ { sect = substr($0, 2, length($0) - 2); next }
		{ print sect "|" $0 }
	' "$1"
}
