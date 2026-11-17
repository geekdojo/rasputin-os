#!/bin/sh
#
# kc-conf.sh — the one reader of the key=value conf grammar Keycloak's conf
# files use (geekdojo/geekdojo-brain#974, F-974-09). Sourced, never run.
#
# Its callers: check-build-options.sh beside it (the build conf, at image
# build), test/identity-config-test.sh and test/api-store-wiring-test.sh (the
# baked keycloak.conf and postgresql.conf, which are written in the same
# grammar so one parser reads all three).
#
#   kc_conf_lines FILE BADFILE
#       Prints each key=value line of FILE on stdout, as written, in order.
#       Blank lines and # comment lines are skipped. A key is
#       [A-Za-z0-9._-]+ and the line must start with it. At the first line
#       that is none of these it writes that line's number to BADFILE, stops,
#       and returns 1; the lines before it have already been printed.
#       Returns 0 otherwise. FILE must exist and be readable: the caller
#       checks that first and says so in its own words.

kc_conf_lines() {
	awk -v bad="$2" '
		/^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
		/^[A-Za-z0-9._-]+=/ { print; next }
		{ print NR > bad; exit 1 }
	' "$1"
}
