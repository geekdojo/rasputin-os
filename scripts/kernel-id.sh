#!/bin/sh
#
# kernel-id.sh — print the identity of a kernel image file, in the exact form a
# running kernel reports it: "$(uname -r) $(uname -v)", one line.
#
#   usage: scripts/kernel-id.sh <kernel image>
#
# The identity is the release (UTS_RELEASE, "6.12.47-v8-16k") plus the build
# version (UTS_VERSION, "#1 SMP PREEMPT Sat Oct  3 01:02:03 UTC 2026"). The
# release alone is NOT enough: dev.276 changed the Pi kernel config without
# changing its release string, and that skew is what broke docker on every
# arm64 node (geekdojo/geekdojo-brain#807). The build version carries the build
# timestamp, so two builds of one release differ.
#
# Callers:
#   - post-build.sh bakes one line per kernel into /usr/lib/rasputin/kernel-ids,
#     which rasputin-kernel-match compares against uname on every boot.
#   - test/bundle-kernel-match.sh checks the bundle's kernels against that file.
#   - test/update-smoke.sh compares the kernel a node booted after an update with
#     the kernel the new build produced.
#
# Two formats, told apart by their headers:
#   x86 bzImage   "HdrS" at 0x202. The setup header's kernel_version field
#                 (u16 at 0x20E) points, +0x200, at "R (user@host) V". The
#                 payload is compressed, so the banner itself is not readable.
#   arm64 Image   "ARM\x64" at 0x38. Uncompressed, so the linux_banner string
#                 "Linux version R (user@host) (compiler) V" is in it verbatim —
#                 the same text /proc/version prints. (dev.276 kernel_2712.img:
#                 "Linux version 6.6.28-v8-16k (runner@...) (...) #1 SMP PREEMPT
#                 Sun Oct  4 01:36:08 UTC 2026".)
# In both, V starts at the first " #" (UTS_VERSION always begins "#<n>").
#
# Exit: 0 with the id on stdout; 1 when the file is not a kernel this knows or
# carries no readable identity.
set -eu

f="${1:?usage: kernel-id.sh <kernel image>}"
[ -f "$f" ] || { echo "kernel-id: no such file: $f" >&2; exit 1; }

bytes_at() { # bytes_at OFFSET COUNT — the bytes as text, NULs dropped
	dd if="$f" bs=1 skip="$1" count="$2" 2>/dev/null | tr -d '\000'
}

if [ "$(bytes_at 514 4)" = "HdrS" ]; then
	# shellcheck disable=SC2046 # od prints two numbers; splitting them is the point
	set -- $(od -An -t u1 -j 526 -N 2 "$f")
	[ $# -eq 2 ] || { echo "kernel-id: $f: unreadable kernel_version field" >&2; exit 1; }
	off=$(( $1 + $2 * 256 + 512 ))
	text="$(dd if="$f" bs=1 skip="$off" count=512 2>/dev/null | tr '\000' '\n' | head -1)"
	release="${text%% *}"
elif [ "$(bytes_at 56 3)" = "ARM" ]; then
	# Only the COMPLETE banner: a 6.x Image also carries a placeholder from the
	# first link stage ("... # SMP PREEMPT ", no build number or date), and that
	# one is not what /proc/version prints. More than one distinct complete
	# banner means this is not a single kernel image.
	text="$(LC_ALL=C grep -a -o -E 'Linux version [^ ]+ [^[:cntrl:]]* #[0-9]+ [^[:cntrl:]]*' "$f" | sort -u || true)"
	[ "$(printf '%s\n' "$text" | wc -l)" -le 1 ] \
		|| { echo "kernel-id: $f carries more than one kernel banner" >&2; exit 1; }
	rest="${text#Linux version }"
	release="${rest%% *}"
else
	echo "kernel-id: $f is neither an x86 bzImage nor an arm64 Image" >&2
	exit 1
fi

case "$text" in
	*" #"*) ;;
	*) echo "kernel-id: $f: no kernel identity found (read '$text')" >&2; exit 1 ;;
esac
version="#${text#* #}"
[ -n "$release" ] || { echo "kernel-id: $f: empty kernel release" >&2; exit 1; }
printf '%s %s\n' "$release" "$version"
