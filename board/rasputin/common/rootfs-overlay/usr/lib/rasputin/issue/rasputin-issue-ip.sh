#!/bin/sh
# Write the node's REAL IP into the console login banner (/run/issue, which
# /etc/issue symlinks to — /etc is read-only squashfs so the banner can't be a
# static file with a live value).
#
# We deliberately do NOT use agetty's `\4` escape: agetty resolves `\4` every
# time it renders the issue (getty start + each respawn), grabbing whatever
# address is up at that instant — so on the bench it cycled through loopback
# (127.x) and link-local (169.254.x) before DHCP settled. Instead we read the
# source address of the default route (`ip route get`), which is EMPTY until a
# real routable address exists (link-local provides no default route), so it
# can never report a bogus IP. We wait for it, then write the banner once.
ISSUE=/run/issue

banner() { printf 'Welcome to Rasputin OS\nIP address: %s\n\n' "$1" > "$ISSUE" 2>/dev/null; }

banner "(acquiring address...)"
agetty --reload 2>/dev/null

ip=""
i=0
while [ "$i" -lt 30 ]; do
	ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.][0-9.]*\).*/\1/p')
	[ -n "$ip" ] && break
	sleep 1
	i=$((i + 1))
done

banner "${ip:-(no network)}"
agetty --reload 2>/dev/null
exit 0
