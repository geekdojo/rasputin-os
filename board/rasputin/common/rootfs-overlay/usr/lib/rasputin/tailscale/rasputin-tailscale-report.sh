#!/bin/sh
# Report, once per boot, whether tailscaled came up and which version it runs,
# as ONE line on /dev/kmsg:
#
#   rasputin-tailscale: state=<is-active> daemon=<version> binary=<version>
#
# state   systemctl is-active tailscaled.service
# daemon  `tailscale version --daemon`: the version the RUNNING daemon reports
#         over its LocalAPI socket, so it proves the daemon answers, not only
#         that a file exists
# binary  `/usr/sbin/tailscaled --version`, through the exact path the unit's
#         ExecStart uses, so a symlink loop at that path shows as binary=none
#
# The QEMU smoke (test/boot-smoke.sh) has no shell into the guest; only kmsg
# reaches its serial console. It fails the build unless state=active and both
# versions equal TAILSCALE_BIN_VERSION. Reports only; changes nothing.

first() { "$@" 2>/dev/null | head -n 1 | tr -d '\r' | tr ' ' '_'; }

state=$(systemctl is-active tailscaled.service 2>/dev/null)
daemon=$(first tailscale version --daemon)
binary=$(first /usr/sbin/tailscaled --version)

echo "rasputin-tailscale: state=${state:-unknown} daemon=${daemon:-none} binary=${binary:-none}" > /dev/kmsg
exit 0
