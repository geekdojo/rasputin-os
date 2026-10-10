#!/bin/sh
#
# checks.sh — the check helpers the functional tests share. Sourced, never run
# (geekdojo/geekdojo-brain#754).
#
#   check LABEL STATUS [DETAIL]
#       Prints "  ok   LABEL" when STATUS is 0. Otherwise prints
#       "  FAIL LABEL" with DETAIL under it and adds one to $fails.
#   yes_if COMMAND [ARG ...]
#       Runs COMMAND and prints 0 if it succeeded, 1 if not: the STATUS that
#       check takes, read through $(...).
#   contains NEEDLE HAYSTACK
#       0 when HAYSTACK contains NEEDLE. Glob matching rather than expr(1):
#       expr prints the match length on stdout, and these results are read
#       through $(...), so its output would be captured alongside the verdict
#       and every such check would read as a failure.
#
# Sourcing sets fails=0. The caller reads $fails for its verdict.

fails=0

check() {
	if [ "$2" = "0" ]; then printf '  ok   %s\n' "$1"
	else printf '  FAIL %s\n       %s\n' "$1" "${3:-}"; fails=$((fails + 1)); fi
}

yes_if() { if "$@"; then echo 0; else echo 1; fi; }

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
