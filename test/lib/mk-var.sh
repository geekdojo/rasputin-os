#!/bin/sh
#
# mk-var.sh — read a variable out of a Buildroot package .mk file with real GNU
# make, so a test compares against the value Buildroot itself would see, not
# against what a sed thought the line said. Sourced, never run
# (geekdojo/geekdojo-brain#798).
#
#   mk_var FILE.mk VAR [NAME=VALUE ...]
#
# Prints VAR's value and returns 0. Any NAME=VALUE arguments are passed to make
# as command-line variables (for example BR2_PACKAGE_OPENBAO=y BR2_aarch64=y),
# so a .mk file's conditionals can be evaluated per target. The .mk file is
# included on its own: Buildroot's macros are undefined, so
# `$(eval $(generic-package))` expands to nothing.
#
# FAILS CLOSED. A missing file, a make that is absent or not GNU make, a make
# error (including a $(error) in the file) and an undefined or empty variable
# each return non-zero, print NOTHING on stdout and write a sentence to stderr.
# A caller that compares the output against an expected value therefore can
# never pass on an empty read.
#
# Needs: GNU make on PATH.

mk_var() {
	_mkv_file="${1:-}"
	_mkv_var="${2:-}"
	if [ -z "$_mkv_file" ] || [ -z "$_mkv_var" ]; then
		echo "The mk_var helper needs a .mk file and a variable name." >&2
		return 2
	fi
	shift 2
	if [ ! -f "$_mkv_file" ]; then
		echo "Could not read $_mkv_var from $_mkv_file. The file does not exist." >&2
		return 1
	fi
	if ! command -v make >/dev/null 2>&1; then
		echo "Could not read $_mkv_var from $_mkv_file. GNU make is not on PATH." >&2
		return 1
	fi
	case "$(make --version 2>/dev/null)" in
		"GNU Make"*) ;;
		*)
			echo "Could not read $_mkv_var from $_mkv_file. The make on PATH is not GNU make." >&2
			return 1
			;;
	esac
	# $(info) prints the value on a line of its own; the empty recipe keeps make
	# from printing anything else.
	if ! _mkv_val="$(printf 'include %s\n$(info $(%s))\n.PHONY: mk-var\nmk-var: ;\n' \
		"$_mkv_file" "$_mkv_var" | make -s --no-print-directory -f - mk-var "$@")"; then
		echo "Could not read $_mkv_var from $_mkv_file. GNU make reported an error for it." >&2
		return 1
	fi
	if [ -z "$_mkv_val" ]; then
		echo "Could not read $_mkv_var from $_mkv_file. It is undefined or empty." >&2
		return 1
	fi
	printf '%s\n' "$_mkv_val"
}
