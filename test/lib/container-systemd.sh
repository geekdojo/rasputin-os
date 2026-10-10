#!/bin/sh
#
# container-systemd.sh — boot systemd as PID 1 in a privileged container and
# wait on facts inside it. Sourced, never run (geekdojo/geekdojo-brain#755).
# test/coredump-functional.sh and test/fallback-address-functional.sh still
# carry their own copies of this code; new tests use these.
#
#   ctr_boot WHAT IMAGE [DOCKER_RUN_OPTION ...]
#       Starts IMAGE's /usr/sbin/init as PID 1 in a privileged container with
#       its own cgroup namespace and tmpfs /run, /run/lock and /tmp, plus any
#       further `docker run` options given. Sets CID, then waits until
#       `systemctl is-system-running` says running or degraded. Returns
#       non-zero, with a sentence naming WHAT, if the container does not start
#       or systemd never gets there.
#   inside COMMAND ...
#       Runs the words as one `sh -c` script inside the container.
#   wait_for FACT CONDITION
#       Runs CONDITION inside the container once a second until it succeeds,
#       for at most $CTR_DEADLINE seconds. On the deadline prints
#       "DEADLINE: after Ns, still not true: FACT" and returns 1. The deadline
#       bounds the test; it is never a claim about the system under test.
#   ctr_cleanup
#       Removes the container, if there is one. Safe to call twice.
#
# The caller sets CTR_DEADLINE before sourcing or calling wait_for, and traps
# its own cleanup, which calls ctr_cleanup.
#
# Needs: docker, with privileged containers.

CID=""

inside() { docker exec "$CID" sh -c "$*"; }

wait_for() {
	_wf_i=0
	while [ "$_wf_i" -lt "${CTR_DEADLINE:?set CTR_DEADLINE before wait_for}" ]; do
		inside "$2" >/dev/null 2>&1 && return 0
		sleep 1
		_wf_i=$((_wf_i + 1))
	done
	echo "  DEADLINE: after ${CTR_DEADLINE}s, still not true: $1"
	return 1
}

ctr_cleanup() {
	[ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1
	CID=""
}

ctr_boot() {
	_cb_what="$1"
	_cb_image="$2"
	shift 2
	ctr_cleanup
	CID=$(docker run -d --privileged --cgroupns=private \
		--tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
		"$@" "$_cb_image" /usr/sbin/init) \
		|| { CID=""; echo "FAILED: the container for $_cb_what could not be started."; return 1; }
	wait_for "systemd is running in the container for $_cb_what" \
		's=$(systemctl is-system-running 2>/dev/null); [ "$s" = running ] || [ "$s" = degraded ]'
}
