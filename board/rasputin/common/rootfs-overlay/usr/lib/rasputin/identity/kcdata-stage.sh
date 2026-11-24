#!/bin/sh
#
# kcdata-stage.sh — the rules for root writing into the identity service's
# data directory, shared by keycloak.service's two staging hooks:
# identity-stage-import.sh (the realm baseline, geekdojo/geekdojo-brain#975)
# and identity-stage-denylist.sh (the password deny list,
# geekdojo/geekdojo-brain#1145). Sourced, never run. Extracted from
# identity-stage-import.sh, so the two hooks cannot disagree on them.
#
# ROOT IN ANOTHER UID'S DIRECTORY. keycloak/data is the keycloak uid's. During
# ExecStartPre= no process of the unit's uid runs (systemd empties the cgroup
# before a start), so these static rules are enough. Before touching anything
# a caller refuses when keycloak/data is not a real directory, a subdirectory
# it writes is present and not a real directory, or a name it replaces is
# present and not a regular file (a symlink is none of these). Names are
# removed only with `rm -f`, which unlinks a symlink and never follows it;
# only names just removed or found absent are created; and `chown -h` runs
# only on what was created. A copy goes in by a rename, which replaces the
# name and never writes through it.
#
#   kcdata_real_dir PATH
#       0 when PATH is a real directory, not a symlink to one; 1 otherwise.
#   kcdata_dir_ok PATH
#       0 when PATH is absent or a real directory; 1 when it is a symlink
#       (dangling included) or any other type.
#   kcdata_file_ok PATH
#       0 when PATH is absent or a regular file; 1 when it is a symlink
#       (dangling included) or any other type.
#   kcdata_mkdir PATH OWNER
#       Creates PATH at 0700 and gives it to OWNER (uid:gid). 1 on failure.
#   kcdata_install SRC DEST OWNER
#       Copies SRC to DEST.tmp (any name there removed first), sets 0600 and
#       OWNER, and renames it over DEST. On failure it removes DEST.tmp and
#       returns 1; DEST is then as it was.
#
# The caller sets umask 077 and logs its own sentence on a 1.

kcdata_real_dir() {
	[ ! -L "$1" ] && [ -d "$1" ]
}

kcdata_dir_ok() {
	[ ! -L "$1" ] && { [ ! -e "$1" ] || [ -d "$1" ]; }
}

kcdata_file_ok() {
	[ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; }
}

kcdata_mkdir() {
	mkdir -m 0700 "$1" && chown -h "$2" "$1"
}

kcdata_install() {
	if ! { rm -f "$2.tmp" && cp "$1" "$2.tmp" && chmod 0600 "$2.tmp" \
		&& chown -h "$3" "$2.tmp" && mv -f "$2.tmp" "$2"; }; then
		# Best effort, its error dropped on purpose: the caller logs the
		# failure next, and the next start begins by removing it.
		rm -f "$2.tmp" 2>/dev/null
		return 1
	fi
	return 0
}
