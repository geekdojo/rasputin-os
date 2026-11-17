#!/bin/sh
#
# armed.sh — the one reading of the identity data's `armed` marker
# (geekdojo/geekdojo-brain#975, Identity 2.7; platform.md §4.1). Sourced, never
# run: identity-db-init-gate.sh and identity-stage-import.sh both read the fact
# through it, so the two never disagree on what `armed` means.
#
#   identity_armed DIR
#       Prints exactly one word:
#         unknown   DIR cannot be listed (missing included), so whether sign-in
#                   was set up cannot be known;
#         armed     DIR's listing names `armed`, whatever its type: a file, a
#                   directory or a dangling symlink;
#         unarmed   otherwise.
#       The listing is the fact, not a stat of DIR/armed, so a link's target
#       and DIR's search bit change nothing. Always returns 0.

identity_armed() {
	if ! _ia_entries=$(ls -A -- "$1" 2>/dev/null); then
		echo unknown
		return 0
	fi
	case "
$_ia_entries
" in
		*"
armed
"*) echo armed ;;
		*) echo unarmed ;;
	esac
	return 0
}
