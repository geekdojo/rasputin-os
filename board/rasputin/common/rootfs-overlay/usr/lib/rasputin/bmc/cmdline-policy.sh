#!/bin/sh
# cmdline-policy.sh — the BMC-host kernel cmdline policy, as a library
# (control-plane/bmc-bitscope.md §5). Sourced, never run.
#
# On the BMC host, serial0 is the command channel to the BitScope BMC bus, so
# the kernel must not print to it: once the bitscope driver unlocks the bus,
# printk on that UART is live command traffic (single-char verbs; '\' is a hard
# power cut). The policy is "no serial console= token in cmdline.txt".
#
# ONE copy, two callers, because the two would otherwise drift:
#   - usr/lib/rasputin/bmc/strip-serial-console.sh (firstboot, on the node)
#     strips both boot slots' cmdline.txt once.
#   - the RAUC bundle hook (board/rasputin/common/rauc-bundle-hook.sh) re-applies
#     it every time an update rewrites a boot slot's cmdline.txt
#     (geekdojo/geekdojo-brain#807). The hook runs on the OLD rootfs, which may
#     predate this file, so post-image.sh copies THIS file into the bundle and
#     the hook sources the copy it shipped with.
#
# Busybox-safe (sed -E is in busybox sed).

# cmdline_has_serial_console FILE — status 0 when FILE carries a serial
# console token: ttyS<n> (the mini-UART, the 40-pin header UART on this image)
# or ttyAMA<n> (PL011, covered defensively; the Pi 5 may enumerate
# differently). The comma+baud requirement keeps console=tty1.
cmdline_has_serial_console() {
	grep -qE 'console=tty(S|AMA)[0-9]+,[0-9]+' "$1"
}

# cmdline_strip_serial_console FILE — print FILE with every serial console
# token removed and the leftover double space collapsed (cmdline is one line).
cmdline_strip_serial_console() {
	sed -E -e 's/console=tty(S|AMA)[0-9]+,[0-9]+ *//g' -e 's/  */ /g' "$1"
}
