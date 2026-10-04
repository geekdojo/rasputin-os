#!/bin/sh
#
# rasputin-kernel-match.sh — once per boot, say whether the running kernel is
# one this rootfs was built for (geekdojo/geekdojo-brain#807).
#
# A kernel and its rootfs are one build: the rootfs's /lib/modules lists which
# drivers are built into THAT kernel (modules.builtin) and ships the rest as
# .ko files. Boot a different kernel and anything the new rootfs expects built
# in is simply missing. That is how dev.276 broke docker on every OTA'd Pi: the
# update replaced the rootfs and left the old kernel, which has bridge as a
# module the new rootfs no longer ships. The bundle now carries the kernel
# (board/rasputin/common/rauc-bundle-hook.sh); this is the guard that says, on
# every boot, whether that held.
#
# post-build.sh bakes /usr/lib/rasputin/kernel-ids: one line per kernel the
# image ships (the rpi ships two, Pi 4 and Pi 5), each "<uname -r> <uname -v>".
# The build version is part of the id because the release string alone did not
# change in dev.276 while the config did.
#
# One verdict line goes to /dev/kmsg, which reaches the serial console, so the
# QEMU smokes assert it with no shell into the guest:
#   rasputin-kernel-match: MATCH running=<id>                 exit 0
#   rasputin-kernel-match: MISMATCH running=<id> built-for=…  exit 1
#   rasputin-kernel-match: FAIL <why>                         exit 1
# Non-zero leaves the unit failed, so `systemctl --failed` shows it too.
#
# RASPUTIN_KERNEL_IDS and RASPUTIN_KMSG are the test seams
# (test/kernel-match-test.sh).
set -u

IDS="${RASPUTIN_KERNEL_IDS:-/usr/lib/rasputin/kernel-ids}"
KMSG="${RASPUTIN_KMSG:-/dev/kmsg}"

say() {
	echo "rasputin-kernel-match: $*"
	# The verdict on stdout is in the journal either way; kmsg is what the
	# console (and so the smoke) sees, and losing it must not change the exit.
	echo "rasputin-kernel-match: $*" > "$KMSG" 2>/dev/null \
		|| echo "rasputin-kernel-match: WARNING could not write the verdict to $KMSG" >&2
}

running="$(uname -r) $(uname -v)"

if [ ! -s "$IDS" ]; then
	say "FAIL no kernel list at $IDS, so nothing says which kernel this rootfs was built for"
	exit 1
fi
if grep -qxF -- "$running" "$IDS"; then
	say "MATCH running=$running"
	exit 0
fi
say "MISMATCH running=$running built-for=$(tr '\n' ';' < "$IDS")"
exit 1
