#!/bin/sh
#
# boot-smoke.sh — boot a built Rasputin OS image headless under QEMU and assert
# it came up correctly. ONE script for BOTH SKUs (os-images/release-pipeline.md).
#
#   usage: test/boot-smoke.sh <amd64|arm64> <path/to/disk.img>
#
# WHY ONE SCRIPT. The amd64 smoke lived inline in release.yml and was the only
# boot test the project had; the rpi SKU was built, signed and published without
# ever being booted. Adding a second inline copy would have created two bodies
# of assertions free to drift — and the assertion that matters most is the one
# nobody remembers to copy across. Everything below `qemu_boot` is
# arch-independent and runs identically for both images.
#
# WHAT IS ARCH-SPECIFIC (and nothing else):
#   - machine + firmware: q35 + OVMF (UEFI) on amd64; `virt` with the image's
#     own kernel loaded directly on arm64 (see the long note in qemu_boot).
#   - CPU model: `-cpu max` on amd64 (the image is built for SSE4.2, which the
#     default qemu64 model lacks); `-cpu cortex-a72` on arm64, the exact
#     BR2_cortex_a72 build target.
#   - console device: ttyS0 on amd64, ttyAMA0 (PL011) on arm64.
# The time budgets are SHARED — measured, arm64 is the faster of the two.
# The root device is addressed by PARTUUID from the image's own cmdline on both,
# so nothing here hardcodes /dev/vda vs /dev/sda.
#
# WHAT IS SHARED: the seed injection, every poll, and every assertion.
#
set -u

ARCH="${1:?usage: boot-smoke.sh <amd64|arm64> <image>}"
IMG="${2:?usage: boot-smoke.sh <amd64|arm64> <image>}"
CONSOLE_LOG="${CONSOLE_LOG:-/tmp/console.log}"
WORK="${WORK:-/tmp/boot-smoke}"

test -f "$IMG" || { echo "::error::no image at $IMG"; exit 1; }
mkdir -p "$WORK"
# Seed lookup, OVMF and the per-arch QEMU line, shared with test/update-smoke.sh.
. "$(dirname "$0")/lib/qemu-common.sh"
# The store readiness check (geekdojo/geekdojo-brain#834): the verdict on the
# api's report, the wait and the post-kill report; and the first-run sign-in
# that reading the report needs, with the soft passkey it runs.
# shellcheck source=test/lib/store-ready.sh
. "$(dirname "$0")/lib/store-ready.sh"
# shellcheck source=test/lib/api-session.sh
. "$(dirname "$0")/lib/api-session.sh"
SOFT_PASSKEY="$(dirname "$0")/lib/soft-passkey.py"

# Host-side forwards into the guest. The same numbers serve both arches: the two
# smoke jobs run on separate runners, so they never collide.
HTTP_PORT=18080
HTTPS_PORT=18443
DNS_PORT=15353
# The guest's :22, used only by guest_diag below, after a store or api check
# has already failed.
SSH_PORT=12222

# Budgets, shared by both arches. These are CEILINGS, not sleeps — every wait
# below polls a checkable fact and exits the moment it is true, so a fast run is
# fast. They are the values the amd64 job was tuned to.
#
# arm64 was given roughly 3x these on the reasoning that a cross-ISA TCG
# translation would need the rope. MEASURED, it does not: on the same runner
# class the arm64 guest reached multi-user in 31s against amd64's 36s, and
# finished the whole script in 137s against 148s. It is faster, not slower —
# `virt` + virtio has far less to emulate than q35 + OVMF. Keeping a separate,
# larger arm64 budget would have been an assumption the numbers contradict, and
# would only have meant a hung arm64 boot burning 45 minutes before saying so.
#
# (The arm64 job also DOESN'T need the rope for a different reason: a dead qemu
# is now detected directly, see die_if_qemu_gone, so the budget is only ever
# reached by a guest that is genuinely stuck.)
# ATREST_TRIES is the at-rest audit verdict poll (2s apart → 120s ceiling). The
# worst case is still inside BOOT_BUDGET: 240 (multi-user) + 120 (firstboot) +
# 240 (api) + 70 (soak) + 120 = 790s against the 900s qemu timeout, so a stuck
# audit is reported by the assertion below rather than by qemu being killed
# out from under the script.
# TS_TRIES is the tailscaled-report poll (2s apart, 60s ceiling). It runs after
# the at-rest poll, by which point multi-user has long been reached and the
# report (ordered only After=tailscaled) has normally already arrived.
# KM_TRIES is the kernel-match verdict poll (2s apart, 60s ceiling); like the
# tailscale report it normally arrived long before the polls above finish.
# SI_TRIES is the secrets store's self-init line (geekdojo/geekdojo-brain#804;
# 2s apart, 60s ceiling). The api mints the store's leaf in the background
# after it starts and then restarts the store, so the line can come after
# /healthz answers; by the end of the polls above it normally has. With it the
# worst case is 790 + 60 + 60 = 910s of polling ceilings, but the tailscale,
# kernel-match and store-init lines are written by then, so those three polls
# end on their first read and the real worst case stays inside the qemu
# timeout; a stuck one is still reported by its own assertion.
# SR_TRIES is the api's report that the secrets store is ready
# (geekdojo/geekdojo-brain#834; 2s apart, 60s ceiling), read from
# GET /api/alerts once the store-init line is in. Like the polls above, it
# ends the moment the fact is true, and a stuck one is reported by its own
# assertion.
# HS_TRIES is the api's HTTPS listener answering /healthz (2s apart, 120s
# ceiling). /healthz on :80 answering does not mean :443 is up: the api binds
# :80 and sends READY first, and starts HTTPS in the background once its clock
# gate opens (rasputin-control-plane api/cmd/rasputin-api/main.go, bounded at
# 90s there), so the ceiling sits above that bound. The api's journal on the
# store-arming smoke (release run 38334384432, arm64) has ":80" listening at
# 67.565s, READY at 67.574s and ":443" listening at 67.653s. Run 38323824127
# asked for the RP ID over :443 within about 2s of READY, got no answer, and
# failed. The poll ends the moment HTTPS answers, normally on its first read;
# its worst case adds 120s to the ceilings above, still inside the qemu
# timeout for the reason given there.
BOOT_BUDGET=900 ; MU_TRIES=120 ; FB_TRIES=60 ; API_TRIES=48 ; HS_TRIES=60 ; ATREST_TRIES=60 ; TS_TRIES=30 ; KM_TRIES=30 ; SI_TRIES=30 ; SR_TRIES=30
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "::error::unknown arch '$ARCH' (expected amd64 or arm64)"; exit 1 ;;
esac

part_offsets() {
  sfdisk -J "$IMG" | jq -r '.partitiontable.partitions[] | "\(.start * 512) \(.type) \(.bootable // false)"'
}

# ---------------------------------------------------------------- seed --------
# Seed role=controlplane so this boot also brings up rasputin-api and we can
# assert the API + bundled web UI actually serve (the shipped seed is blank →
# a role-less boot would never start the api).
#
# RASPUTIN_NODE_ID is required for role=controlplane (firstboot fails loud
# without it — a real CP seed always carries one).
#
# RASPUTIN_CLUSTER_ID is deliberately NOT the default "rasputin". Seeding a real
# cluster name is what makes this smoke exercise the ADR-0003 chain end to end —
# seed -> node.env -> hostname -> the api's derived RP ID. With the default,
# every assertion below would pass even if the whole naming chain were broken,
# because the fallback lands on exactly the values the old hardcodes carried.
CLUSTER_ID=smoke1
#
# RASPUTIN_SSH_AUTHORIZED_KEY is the way into the guest that test/update-smoke.sh
# already uses: firstboot merges it into dropbear's keys, and the seed is the
# only source of one. This script reads its assertions off the console and over
# the api, never over SSH; the key serves guest_diag alone, which dumps the
# store's and the api's journal when one of their checks has failed, so a red
# smoke says why. It is a throwaway key and does not outlive the run.
KEY="$WORK/id_ed25519"
# The growpart leg's disk (geekdojo/geekdojo-brain#853, at the end of this
# script). The trap stops whichever QEMU is still running, waits for it to let
# go of the disk, then removes the key and that copy.
GROW_IMG="$WORK/grow.img"
rm -f "$KEY" "$KEY.pub" "$GROW_IMG"
smoke_cleanup() {
  [ -n "${QPID:-}" ] && kill "$QPID" 2>/dev/null && wait "$QPID" 2>/dev/null
  rm -f "$KEY" "$KEY.pub" "$GROW_IMG"
}
trap smoke_cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -C boot-smoke -f "$KEY" \
  || { echo "::error::ssh-keygen failed; the failure diagnostic would have no way into the guest"; exit 1; }
{
  printf 'RASPUTIN_NODE_ROLE=controlplane\nRASPUTIN_NODE_ID=smoke-cp\nRASPUTIN_CLUSTER_ID=%s\nRASPUTIN_NATS_URL=\nRASPUTIN_CP_JOIN_TOKEN=\n' "$CLUSTER_ID"
  printf 'RASPUTIN_SSH_AUTHORIZED_KEY="%s"\n' "$(cat "$KEY.pub")"
} > "$WORK/seed-cp.env"

# The seed ships on its own auto-mounting FAT partition on BOTH SKUs (the
# running image finds it by FS label RASPUTIN-OS, not by number). We find its
# byte offset from the partition table so the recipe survives a layout change,
# and so ONE selector serves both tables (seed_offset, lib/qemu-common.sh, says
# how). MBR is forced on the Pi because the firmware's autoboot.txt
# boot_partition switch is broken on GPT (rpi-eeprom#654).
#
# mtools keeps the recipe identical to the macOS bench one.
SEED_OFF=$(seed_offset "$IMG")
if [ -z "$SEED_OFF" ]; then
  echo "::error::could not locate the seed partition in $IMG — the table below matches neither the GPT (Microsoft-basic-data) nor the MBR (bootable type 0x0c) seed"
  sfdisk -J "$IMG"
  exit 1
fi
echo "seed partition at byte offset $SEED_OFF"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$IMG"@@"$SEED_OFF" "$WORK/seed-cp.env" ::rasputin-seed.env \
  || { echo "::error::could not write the seed onto the FAT at offset $SEED_OFF"; exit 1; }
# The growpart leg boots this seeded image as a fresh flash, so it is copied
# before the main boot below writes to it.
cp "$IMG" "$GROW_IMG" \
  || { echo "::error::could not copy the seeded image to $GROW_IMG for the growpart leg"; exit 1; }

# ------------------------------------------------------- arch preparation -----
prepare_amd64() {
  # find_ovmf (lib/qemu-common.sh) picks a non-secboot OVMF pair.
  if ! find_ovmf; then
    echo "::error::OVMF firmware not found"; ls -la /usr/share/OVMF/ || true; exit 1
  fi
  echo "using OVMF code=$OVMF_CODE vars=$OVMF_VARS"
  cp "$OVMF_VARS" "$WORK/vars.fd"
  VARS_FD="$WORK/vars.fd"
}

prepare_arm64() {
  # The kernel and the cmdline come OUT OF THE IMAGE, from boot slot A's FAT —
  # not from the source tree — so a regression in what the build stages onto the
  # boot partition fails HERE rather than on a Pi. `virt` has no Pi firmware to
  # read config.txt and pick a kernel, so slot A's kernel is loaded directly.
  BOOT_OFF=""
  for off in $(part_offsets | awk '$2 == "c" && $3 != "true" { print $1 }'); do
    if MTOOLS_SKIP_CHECK=1 mdir -i "$IMG"@@"$off" ::kernel_2712.img >/dev/null 2>&1; then
      BOOT_OFF="$off"; break
    fi
  done
  if [ -z "$BOOT_OFF" ]; then
    echo "::error::no boot slot in $IMG carries kernel_2712.img — post-image.sh stopped staging the Pi 5/CM5 kernel onto the boot FATs, so no Pi 5 or CM5 would boot this image at all"
    part_offsets
    exit 1
  fi
  echo "boot slot A FAT at byte offset $BOOT_OFF"
  MTOOLS_SKIP_CHECK=1 mcopy -o -i "$IMG"@@"$BOOT_OFF" ::kernel_2712.img ::cmdline.txt "$WORK/" \
    || { echo "::error::could not read kernel_2712.img + cmdline.txt out of boot slot A"; exit 1; }

  # The SHIPPED cmdline, verbatim, plus exactly two harness additions — so a
  # regression in root= / rootfstype= / rauc.slot / cgroup_enable fails here.
  #
  #   console=ttyAMA0 — `virt`'s only serial is a PL011. The image's own
  #     console=ttyS0 is the Pi's UART and has no device here; appending ours
  #     LAST makes it /dev/console. The shipped console= arguments are left in
  #     place rather than stripped: they are part of what is under test.
  #   systemd.log_target=kmsg — on amd64 the multi-user marker this script greps
  #     for arrives as the getty issue banner, because the image's getty port
  #     (ttyS0) IS the amd64 console. On the Pi the getty is on the Pi's ttyS0,
  #     which `virt` does not have, and PID 1 stops mirroring unit status to the
  #     console once journald is up — so without this the boot would complete in
  #     silence and the smoke could not tell "reached multi-user" from "hung".
  #     Routing PID 1's own log to kmsg puts it on the console.
  #     (Measured on the bench VM: systemd.journald.forward_to_console=1 does
  #     NOT do this — it forwards journal entries, not PID 1's transitions.)
  CMDLINE="$(tr -d '\n' < "$WORK/cmdline.txt") systemd.log_target=kmsg console=ttyAMA0,115200"
  echo "kernel cmdline: $CMDLINE"
  QEMU_KERNEL="$WORK/kernel_2712.img"
  QEMU_APPEND="$CMDLINE"
}

# ---------------------------------------------------------------- boot --------
# WHY `virt` AND NOT `raspi4b` FOR arm64. QEMU 8+ does model a Pi 4B, and this
# image's own kernel + DTB boot on it — measured, it reaches multi-user. But
# QEMU disables the board's GENET NIC ("brcm,bcm2711-genet-v5 has been
# disabled!") and its USB host controller never enumerates, so a raspi4b guest
# has NO network at all. Every assertion that matters most below — healthz, the
# web UI, the CP nameserver, the WebAuthn RP ID, the uptime soak — is made over
# a hostfwd. On raspi4b this smoke would collapse to "it reached multi-user",
# which is exactly the quiet shrinking this job exists to avoid. `virt` + virtio
# keeps arm64's assertion set identical to amd64's.
#
# The cost is real and is stated in the PR: `virt` is not a Pi. The EEPROM
# bootloader stage, autoboot.txt `boot_partition` A/B switching and the one-shot
# `tryboot` flag are firmware behaviour no emulation here reproduces, and
# config.txt / start4.elf are never read. Those stay bench-only.
qemu_boot() {
  # The machine, CPU, disk and NIC lines are in qemu_exec (lib/qemu-common.sh),
  # shared with the update smoke; the reasoning for each option follows.
  #
  # amd64 — -cpu max: advertise every ISA extension QEMU's TCG knows. The image
  # is built with BR2_x86_corei7 (Nehalem baseline → SSE4.2); the default qemu64
  # CPU model lacks SSE4.2 so glibc's dynamic linker hits "invalid opcode" the
  # moment init runs. Real N100 hardware has SSE4.2+ so the build target is
  # correct — this only affects emulation. (max works without KVM, which not
  # all GH runners expose at /dev/kvm.)
  # user-mode NIC with a host forward so the runner can curl the api/UI;
  # virtio-net matches the virtio-blk the image already boots from. The api
  # listens on :80 (HTTP bootstrap surface; RASPUTIN_HTTP_ADDR=:80 in
  # rasputin-api.service — the old :8080 default is gone from the image).
  # /healthz stays plain-HTTP by contract. mDNS is NOT asserted: user-mode
  # networking makes multicast useless.
  #
  # arm64 — gic-version is pinned rather than left to QEMU's per-version
  # default, so a runner-image bump cannot silently change the interrupt
  # controller under us; the kernel carries both ARM_GIC and ARM_GIC_V3.
  # romfile= (empty) disables the NIC's PXE option ROM. Ubuntu's
  # qemu-system-x86 depends on ipxe-qemu and qemu-system-arm does NOT, so on
  # the arm64 runner virtio-net-pci dies at startup with `failed to find
  # romfile "efi-virtio.rom"` — QEMU never runs at all. We boot with -kernel
  # and never PXE, so the ROM is dead weight; dropping it beats adding a
  # package dependency to get a ROM we would not use.
  qemu_exec "$ARCH" "$IMG" "$BOOT_BUDGET" "$CONSOLE_LOG" \
    "hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${HTTPS_PORT}-:443,hostfwd=udp:127.0.0.1:${DNS_PORT}-:53,hostfwd=tcp:127.0.0.1:${DNS_PORT}-:53,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
}

"prepare_$ARCH"
: > "$CONSOLE_LOG"
START=$(date +%s)
qemu_boot &
QPID=$!

# ---------------------------------------------------------------- polls -------
# Every wait below is a poll on a checkable fact with a hard try count, never a
# bare sleep: it exits the instant the fact is true, and the assertions further
# down name exactly which fact never became true.
#
# Every poll ALSO checks that qemu is still alive. A poll that only watches the
# console cannot tell "the guest is still booting" from "qemu died on its
# command line a second ago", and burns its whole budget either way: the first
# green build of this job spent 901s waiting for a multi-user marker from a
# QEMU that had exited immediately over a missing option ROM, then reported
# "did not reach multi-user" — true, and useless. QEMU's own errors go to
# $CONSOLE_LOG (its stderr), so the cause is already in hand; this just stops
# waiting and prints it.
qemu_gone() { kill -0 "$QPID" 2>/dev/null && return 1 || return 0; }
die_if_qemu_gone() {
  qemu_gone || return 0
  echo "::error::qemu exited on its own while waiting for $1 — it did not run long enough to be killed here. This is usually QEMU refusing its command line (a missing option ROM, an unsupported machine or CPU on the runner's QEMU), not a guest failure; QEMU's own message is in the console below, above any kernel output."
  echo "----- console (whole file) -----"; cat "$CONSOLE_LOG" || true
  exit 1
}

ok=0
i=0
while [ "$i" -lt "$MU_TRIES" ]; do
  if grep -qE "Reached target .*Multi-User|Welcome to Rasputin" "$CONSOLE_LOG"; then ok=1; break; fi
  die_if_qemu_gone "multi-user"
  i=$((i + 1)); sleep 2
done
MU_AT=$(( $(date +%s) - START ))

# Do NOT kill qemu yet: the getty prompt races firstboot (parallel multi-user
# jobs; firstboot waits on makefs→mount of the persistent partition and finishes
# a few seconds AFTER the login prompt). dev.2 false-failed by asserting the
# instant multi-user showed. Keep the same boot running and poll — a second boot
# can't work, firstboot is guarded by the .provisioned stamp it just wrote.
fb=0
if [ "$ok" = 1 ]; then
  i=0
  while [ "$i" -lt "$FB_TRIES" ]; do
    if grep -q "rasputin-firstboot: provisioning complete" "$CONSOLE_LOG"; then fb=1; break; fi
    die_if_qemu_gone "firstboot to complete"
    i=$((i + 1)); sleep 2
  done
fi
FB_AT=$(( $(date +%s) - START ))

# API + web UI smoke (same boot, via the hostfwd to guest :80): the seed above
# made this a controlplane, so rasputin-api must come up and answer /healthz
# over plain HTTP on :80 (that stays the contract even after the HTTPS listener
# lands). GET / on :80 passes as either the bundled UI HTML (api 0.3.x,
# HTTP-only) or a redirect to the HTTPS origin (api with native TLS treats :80
# as a bootstrap/redirect surface) — accept both so the smoke doesn't break
# across the api's HTTPS rollout.
api=0 ui=0 https=0 NSUDP="" NSTCP="" RPID="" HS_FIRST=""
if [ "$fb" = 1 ]; then
  i=0
  while [ "$i" -lt "$API_TRIES" ]; do
    if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${HTTP_PORT}/healthz" || true)" = "200" ]; then api=1; break; fi
    die_if_qemu_gone "the api to answer /healthz"
    i=$((i + 1)); sleep 5
  done
  if [ "$api" = 1 ]; then
    rcode=$(curl -s -o "$WORK/root.body" -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HTTP_PORT}/" || true)
    root=$(cat "$WORK/root.body" 2>/dev/null || true)
    case "$root" in *"<html"*|*"<!DOCTYPE"*) ui=1;; esac
    case "$rcode" in 301|302|307|308) ui=1;; esac
    # The HTTPS listener, waited for as its own fact before anything is asked
    # over it (HS_TRIES above). The first read's answer is kept, so the
    # timings line shows whether :443 lagged :80 on this run.
    i=0
    while [ "$i" -lt "$HS_TRIES" ]; do
      hs=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 2 "https://127.0.0.1:${HTTPS_PORT}/healthz" || true)
      [ -n "$HS_FIRST" ] || HS_FIRST="${hs:-000}"
      if [ "$hs" = "200" ]; then https=1; break; fi
      die_if_qemu_gone "the api's HTTPS listener to answer /healthz"
      i=$((i + 1)); sleep 2
    done
    # Capture the api's WebAuthn RP ID while the VM is STILL RUNNING. It is
    # asserted further down with the console checks, but it can only be
    # COLLECTED here: everything below runs after the qemu kill, so an HTTP call
    # there talks to a dead machine and returns nothing — which reads exactly
    # like a failed derivation.
    # HTTPS because :80 is only the bootstrap/redirect surface; -k because the
    # leaf is signed by the per-installation Mesh CA. Unauthenticated on
    # purpose: first-user registration is open until a user exists, which is
    # this freshly-provisioned box.
    [ "$https" = 1 ] && RPID=$(curl -sk --max-time 10 -X POST "https://127.0.0.1:${HTTPS_PORT}/api/auth/register/begin" \
      -H 'Content-Type: application/json' \
      -d '{"name":"smoke","displayName":"Smoke Test"}' | jq -r '.publicKey.rp.id // empty')
    # CP nameserver (ADR-0004 §3/§8): ask the guest's own :53 for the cluster
    # zone apex over BOTH transports, via the hostfwd on the qemu line.
    # Collected here for the same reason as RPID.
    #
    # Queried rather than grepped from the console because the api logs to the
    # journal — its "nameserver authoritative for ..." line is not on the serial
    # console. As with RPID, asking is the stronger check anyway: it proves the
    # responder ANSWERS, not that something printed.
    #
    # UDP and TCP are asked SEPARATELY on purpose. The api binds the two
    # transports independently (control-plane #126 — deriving the TCP port from
    # the UDP bind was a TOCTOU that intermittently failed CI), so a UDP answer
    # says nothing about TCP.
    #
    # This is worth a gate because the failure is SILENT: a nameserver bind
    # error is deliberately non-fatal (the api logs it and serves on without
    # DNS, on the reasoning that a control plane that won't start is worse than
    # one that won't resolve). Nothing crashes, healthz stays 200, and no other
    # assertion here would notice the cluster had lost name resolution. No poll
    # needed: the api binds :53 long before it listens on :80, so healthz
    # answering means the bind already succeeded or already failed.
    NSUDP=$(dig +short +time=5 +tries=2 @127.0.0.1 -p "$DNS_PORT" "${CLUSTER_ID}.internal" A 2>/dev/null | head -1)
    NSTCP=$(dig +short +time=5 +tries=2 +tcp @127.0.0.1 -p "$DNS_PORT" "${CLUSTER_ID}.internal" A 2>/dev/null | head -1)
  fi
fi
API_AT=$(( $(date +%s) - START ))

# Uptime soak: retry-until-success probes are blind to a crash loop (the api's
# missing sd_notify watchdog support meant every hardware boot SIGABRT-cycled it
# every ~33s for FIVE releases, and this smoke passed every time — found
# 2026-06-12 on the Mu bench). 70s straddles two 30s watchdog windows: if any
# unit is being watchdog-killed, healthz at the end fails and/or the console
# shows the kill. Both are asserted after shutdown below.
# Probe CONTINUOUSLY (every 2s for 70s, every probe must pass): a single
# end-of-window probe would land inside a crash loop's ~28s live window ~85% of
# the time — the exact blindness that let the bug ship. A 33s kill cycle has a
# 4-5s dead window that 2s-interval probes cannot miss.
#
# The soak is wall-clock on BOTH arches on purpose: the watchdog window it has
# to straddle is wall-clock on the guest too, so shortening it under emulation
# would quietly make it stop straddling anything.
soak=0
if [ "$api" = 1 ]; then
  soak=1
  i=0
  while [ "$i" -lt 35 ]; do
    sleep 2
    die_if_qemu_gone "the uptime soak to finish"
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${HTTP_PORT}/healthz" || true)" = "200" ] \
      || { soak=0; break; }
    i=$((i + 1))
  done
fi
# At-rest file modes (geekdojo/geekdojo-brain#494, gate 7). The audit runs once
# per boot and writes ONE verdict line to /dev/kmsg, which is why it is
# greppable here at all — it has no other channel into this script, which has no
# shell into the guest.
#
# WAITED FOR, NOT ASSUMED PRESENT. rasputin-atrest-audit.service is
# WantedBy=multi-user.target and ordered After=rasputin-api.service, so its
# verdict can land well after every assertion above: on a controlplane boot it
# does not even start until the api has, and it audits the files the api wrote.
# Polled like everything else here — the instant the line appears this stops
# waiting — and it is polled BEFORE the qemu kill below, because a verdict that
# had not arrived yet would otherwise be indistinguishable from one that never
# will.
#
# Only the ARRIVAL is polled. The line itself is read back out of the console
# after the kill, with qemu no longer appending to it: a grep against a file
# being written can catch a half-flushed line, and "checked=2" out of a
# still-arriving "checked=20" would be a real-looking number that nothing else
# would contradict.
atrest=0
if [ "$ok" = 1 ]; then
  i=0
  while [ "$i" -lt "$ATREST_TRIES" ]; do
    if grep -qE "rasputin-atrest: (PASS|FAIL)" "$CONSOLE_LOG"; then atrest=1; break; fi
    die_if_qemu_gone "the at-rest audit verdict"
    i=$((i + 1)); sleep 2
  done
fi
ATREST_AT=$(( $(date +%s) - START ))

# tailscaled state + version (EXPERIMENT, spike/own-tailscale). The image's
# rasputin-tailscale-report.service writes ONE "rasputin-tailscale:" line to
# /dev/kmsg once tailscaled is ready or has failed. Only its arrival is polled
# here, before the kill, for the same reason as the at-rest verdict above; it is
# read back and asserted after the kill.
tsrep=0
if [ "$ok" = 1 ]; then
  i=0
  while [ "$i" -lt "$TS_TRIES" ]; do
    if grep -qa "rasputin-tailscale: " "$CONSOLE_LOG"; then tsrep=1; break; fi
    die_if_qemu_gone "the tailscaled report"
    i=$((i + 1)); sleep 2
  done
fi
TS_AT=$(( $(date +%s) - START ))

# Kernel/rootfs match (geekdojo/geekdojo-brain#807). rasputin-kernel-match.service
# writes ONE "rasputin-kernel-match:" verdict to /dev/kmsg per boot. Arrival is
# polled here, before the kill; the verdict is asserted after it.
kmrep=0
if [ "$ok" = 1 ]; then
  i=0
  while [ "$i" -lt "$KM_TRIES" ]; do
    if grep -qa "rasputin-kernel-match: " "$CONSOLE_LOG"; then kmrep=1; break; fi
    die_if_qemu_gone "the kernel-match verdict"
    i=$((i + 1)); sleep 2
  done
fi
KM_AT=$(( $(date +%s) - START ))

# The secrets store's self-init (geekdojo/geekdojo-brain#804, TC-804-23).
# rasputin-store-init.sh writes one "rasputin-store-init:" line to /dev/kmsg
# when the store's first start ends, initialised or failed, and the store's
# provisioner (#805, TC-805-35) one "rasputin-store-provision:" line when its
# run after that start ends. Arrival of both is polled here, before the kill;
# the outcomes are asserted after it.
sirep=0
if [ "$api" = 1 ]; then
  i=0
  while [ "$i" -lt "$SI_TRIES" ]; do
    if grep -qa "rasputin-store-init: " "$CONSOLE_LOG" && grep -qa "rasputin-store-provision: " "$CONSOLE_LOG"; then sirep=1; break; fi
    die_if_qemu_gone "the secrets store's self-init line"
    i=$((i + 1)); sleep 2
  done
fi
SI_AT=$(( $(date +%s) - START ))

# The api reports the secrets store ready (geekdojo/geekdojo-brain#834). Its
# only report is GET /api/alerts, which needs a session: a store in any state
# but ready raises a "secret-store:" alert there. The smoke signs in through
# first-run registration, open on this fresh control plane, then polls the
# list here, before the kill, and the outcome is asserted after it. Only once
# the store-init line is in: until then there is nothing to ask about.
#
# The SR_ variables are set before the gate because this script runs under
# set -u, and the report reads all of them on every path.
SR_STAGE="" SR_REASON="" SR_RC="" SR_LAST="" SR_AT=""
SR_JAR="$WORK/store-ready.jar"
# smoke_post URL BODYFILE OUTFILE JAR — api_session's POST.
smoke_post() {
  curl -sk -c "$4" -b "$4" --max-time 10 -H 'Content-Type: application/json' \
    --data-binary "@$2" -o "$3" -w '%{http_code}' "$1" || true
}
# smoke_fetch — store_ready_wait's FETCH: prints the code and the body's path.
smoke_fetch() {
  rm -f "$WORK/alerts.body"
  printf '%s %s\n' "$(curl -sk -b "$SR_JAR" --max-time 5 -o "$WORK/alerts.body" -w '%{http_code}' \
    "https://127.0.0.1:${HTTPS_PORT}/api/alerts" || true)" "$WORK/alerts.body"
}
if [ "$sirep" = 1 ]; then
  (umask 077; : > "$SR_JAR")
  mkdir -p "$WORK/store-ready"
  SR_STAGE="signin"
  if SR_REASON=$(api_session smoke_post "https://127.0.0.1:${HTTPS_PORT}" "https://${RPID}" "$SR_JAR" "$WORK/store-ready" "$SOFT_PASSKEY"); then
    SR_STAGE="wait"
    store_ready_wait "$SR_TRIES" 2 smoke_fetch die_if_qemu_gone
    SR_RC=$?
  fi
fi
SR_AT=$(( $(date +%s) - START ))

TOTAL=$(( $(date +%s) - START ))

# The failure diagnostic. The store's and the api's own logs go to the guest's
# journal, which does not reach the console, so a store or api check that
# fails below would otherwise say only which fact never came true, never why.
# When one of those facts is already false here, before the kill, the guest is
# asked over SSH for those units' journal, the store's data directory and
# outcome record, and the kernel's console loglevel and cmdline, and the answer
# is printed in the job log. It is printed, never asserted on: the assertions
# below still decide the verdict, and a diagnostic that cannot reach the guest
# says so and changes nothing.
guest_diag_needed() {
  [ "$api" = 1 ] || return 0
  [ "$https" = 1 ] || return 0
  [ "$RPID" = "${CLUSTER_ID}.local" ] || return 0
  [ "$sirep" = 1 ] || return 0
  grep -aq 'rasputin-store-init: outcome=initialised' "$CONSOLE_LOG" || return 0
  grep -aqE 'rasputin-store-(init|provision): outcome=failed' "$CONSOLE_LOG" && return 0
  [ "$SR_STAGE" = wait ] && [ "$SR_RC" = 0 ] || return 0
  return 1
}
guest_diag() {
  echo "::group::guest diagnostic: the store's and the api's journal (a store or api check is about to fail)"
  SSH_CALL_TIMEOUT=120 ssh_guest '
    echo "== /proc/sys/kernel/printk (console loglevel first): $(cat /proc/sys/kernel/printk)"
    echo "== /proc/cmdline: $(cat /proc/cmdline)"
    echo "== ls -lan /var/lib/rasputin/openbao"; ls -lan /var/lib/rasputin/openbao
    echo "== ls -lan /run/rasputin-store-init"; ls -lan /run/rasputin-store-init
    echo "== /run/rasputin-store-init/outcome"; cat /run/rasputin-store-init/outcome
    echo "== the kernel ring buffer: rasputin-store lines"; dmesg | grep rasputin-store
    echo "== systemctl show openbao.service"
    systemctl show openbao.service -p ActiveState -p SubState -p Result -p NRestarts -p ExecMainStatus
    echo "== journalctl -b -u openbao.service -u rasputin-store-provision.service"
    journalctl -b -o short-monotonic --no-pager -u openbao.service -u rasputin-store-provision.service
    echo "== journalctl -b -u rasputin-api.service"
    journalctl -b -o short-monotonic --no-pager -u rasputin-api.service
  ' 2>&1 || echo "guest_diag: the guest did not answer over SSH (status $?), so there is no journal to show"
  echo "::endgroup::"
}
if guest_diag_needed; then guest_diag; fi

kill "$QPID" 2>/dev/null || true
echo "----- last 60 lines of console -----"; tail -60 "$CONSOLE_LOG" || true
echo "----- $ARCH smoke timings (seconds from qemu start) -----"
echo "https /healthz on its first read after :80 answered: HTTP ${HS_FIRST:-not asked}"
echo "multi-user=${MU_AT}s firstboot=${FB_AT}s api+ui+dns=${API_AT}s atrest-verdict=${ATREST_AT}s tailscale-report=${TS_AT}s kernel-match=${KM_AT}s store-init=${SI_AT}s store-ready=${SR_AT}s total(incl. 70s soak)=${TOTAL}s"

# ------------------------------------------------------------ assertions ------
[ "$ok" = 1 ] || { echo "::error::$ARCH image did not reach multi-user in QEMU"; exit 1; }
echo "$ARCH image booted to multi-user in QEMU"

# firstboot logs to /dev/kmsg, so its lines reach the serial console. (Asserting
# on systemd's own "Mounted ..." line doesn't work: PID 1 stops mirroring unit
# status to the console once journald is up, which is before the seed device is
# found — learned on dev.1.)
grep -q "rasputin-firstboot: reading seed /run/rasputin-seed/rasputin-seed.env" "$CONSOLE_LOG" \
  || { echo "::error::firstboot never read the seed — /run/rasputin-seed wiring (or kmsg logging) regressed"; exit 1; }
# "provisioning complete" proves the persistent partition mounted (makefs+growfs
# path) and node.env was written — a fresh board otherwise fails provisioning on
# read-only /etc (Mu bring-up 2026-06-09).
[ "$fb" = 1 ] \
  || { echo "::error::firstboot did not complete — persistent mount (e2fsprogs/makefs?) or node.env write failed; see console artifact"; exit 1; }
echo "seed read + provisioning completion confirmed in boot output"

# Per-role hostname: rasputin-hostname.service runs every boot (after firstboot,
# before the api) and logs to kmsg like firstboot does. On this
# controlplane-seeded boot it must have promoted the baked "rasputin-node"
# placeholder to the seeded cluster name — that transient hostname is what
# resolved announces as <cluster>.local (mDNS itself can't be asserted under
# user-mode networking).
grep -q "rasputin-hostname: transient hostname set to ${CLUSTER_ID} (role=controlplane)" "$CONSOLE_LOG" \
  || { echo "::error::the controlplane hostname did not follow RASPUTIN_CLUSTER_ID — the seeded cluster name never reached the hostname (check firstboot node.env pass-through and rasputin-hostname.sh); the cluster would be unreachable at ${CLUSTER_ID}.local; see console artifact"; exit 1; }
echo "per-cluster hostname (${CLUSTER_ID}) confirmed in boot output"

# The HTTPS listener answered before anything was asked over it (HS_TRIES).
if [ "$api" = 1 ] && [ "$https" != 1 ]; then
  echo "::error::the api answered /healthz on :80 but its HTTPS listener on :443 never answered /healthz in $((HS_TRIES * 2))s (first read: HTTP ${HS_FIRST:-000}) — the browser surface is down: the api's clock gate never opened, its leaf did not load, or the listener failed to bind; see the api journal above"
  exit 1
fi
[ "$api" = 1 ] && echo "api HTTPS listener answered /healthz on :443"

# The api must DERIVE its WebAuthn identity from the same cluster id. This is
# the assertion the naming work most needs: credentials bind to the RP ID, so a
# wrong derivation does not error — it produces a cluster whose passkeys
# silently cannot be used.
if [ "$RPID" != "${CLUSTER_ID}.local" ]; then
  echo "::error::the api's WebAuthn RP ID is '${RPID:-<no response>}', expected '${CLUSTER_ID}.local' — it did not derive from RASPUTIN_CLUSTER_ID. Every passkey would bind to the wrong origin."
  grep -o "rasputin-api: cluster identity:.*" "$CONSOLE_LOG" || true
  exit 1
fi
echo "api derived its WebAuthn RP ID from the cluster id ($RPID)"

# The cluster zone must resolve over UDP *and* TCP. Both answers are the CP's
# own LAN IP (the SLIRP guest address); the value is checked for shape rather
# than pinned to 10.0.2.15 so a qemu networking change doesn't false-fail this.
case "$NSUDP" in
  ''|*[!0-9.]*)
    echo "::error::the CP nameserver did not answer ${CLUSTER_ID}.internal over UDP on the guest's :53 (got '${NSUDP:-<no answer>}') — the responder failed to bind, or never started. This failure is SILENT on real hardware: the bind error is non-fatal, so the control plane serves on with no name resolution and healthz still returns 200. Check the api journal for 'nameserver not started'."
    exit 1;;
esac
case "$NSTCP" in
  ''|*[!0-9.]*)
    echo "::error::the CP nameserver answered ${CLUSTER_ID}.internal over UDP but NOT TCP (got '${NSTCP:-<no answer>}') — the TCP listener failed to bind. Resolvers fall back to TCP for answers truncated past 512 bytes, so this breaks only large responses: precisely the regression that ships unnoticed. See control-plane #126 for why the two transports bind independently."
    exit 1;;
esac
if [ "$NSUDP" != "$NSTCP" ]; then
  echo "::error::the CP nameserver returned different addresses for ${CLUSTER_ID}.internal over UDP ($NSUDP) and TCP ($NSTCP) — the two listeners are not serving the same handler."
  exit 1
fi
echo "CP nameserver answered ${CLUSTER_ID}.internal over UDP and TCP ($NSUDP)"

# No unit file may carry a malformed Environment= assignment.
#
# systemd's Environment= splits on whitespace, so an unquoted value containing a
# space is silently truncated and the remainder is dropped. That shipped:
# RASPUTIN_MDNS_RECOVER_CMD reached the agent as bare "systemctl", so the mDNS
# name guard's recovery ran `sh -c "systemctl"` and repaired nothing — for an
# entire release, past green CI, a clean security review, and a 93% mutation
# gate. Detection kept working, which is what made it invisible.
#
# systemd DID warn, on the console, on every boot:
#   /etc/systemd/system/rasputin-agent.service:29: Invalid environment
#   assignment, ignoring: restart
# Nobody was reading. This turns that warning into a build failure.
#
# Deliberately generic rather than asserting one expected value: it guards EVERY
# unit's Environment= lines, and it needs nothing from the guest beyond the
# console we already capture (the smoke has no shell in, and dumping the agent's
# env would leak RASPUTIN_CP_JOIN_TOKEN).
if grep -n "Invalid environment assignment" "$CONSOLE_LOG"; then
  echo "::error::a unit file has a malformed Environment= line (see the matches above) — systemd truncated the value at the first space, so the process is running with a silently wrong environment. Quote the whole assignment: Environment=\"VAR=value with spaces\""
  exit 1
fi
echo "no malformed Environment= assignments in any unit"

# A unit that systemd could not even exec. Before a service's process runs,
# systemd sets up its sandbox — state/cache/runtime directories, namespaces,
# credentials — and a failure there is reported as "Failed at step <STEP>
# spawning <binary>" and an exit status of 2xx/<STEP>. Nothing in the image
# has to be wrong for this to happen: a systemd bump can change how a setting
# is applied. The first Buildroot 2026.08 build (run 36935416907) booted to
# multi-user with every assertion above green while tailscaled failed at
# STATE_DIRECTORY on every start, because systemd 258 no longer follows the
# image's /var/lib/tailscale symlink — mesh enrollment would have been dead on
# every node. tailscaled's CACHE_DIRECTORY failure, found on the bench on
# 2026-06-18 (dev.20), was the same class.
#
# Generic on purpose, like the Environment= check: it covers every unit, and
# no unit on this image is expected to fail its exec setup. Coverage is the
# arm64 console: there systemd.log_target=kmsg (above) puts the service
# manager's per-unit errors on the console. The amd64 console stops carrying
# them once journald is up, so on amd64 this check sees only early boot.
if grep -anE "Failed at step [A-Z_]+ spawning" "$CONSOLE_LOG"; then
  echo "::error::a unit failed while systemd was setting up its execution environment, before its process ran (see the matches above; the step name says which setting). Its service never started."
  exit 1
fi
echo "no unit failed its execution-environment setup"

# tailscaled is running and is the version the image pins (EXPERIMENT,
# spike/own-tailscale). Buildroot 2026.08's tailscale package made
# /usr/sbin/tailscaled a symlink to itself (run 36944490353). The arm64 smoke
# caught it only through the generic "Failed at step" check above; the amd64
# smoke passed the same broken rootfs, because its console never carries
# per-unit errors once journald is up and nothing asserted on tailscaled. This
# assertion reads a kmsg line, which reaches BOTH consoles, so it covers both
# arches. The expected version is read from the package that installs it, so a
# version bump cannot leave this check behind.
TS_EXPECT="$(sed -n 's/^TAILSCALE_BIN_VERSION = //p' "$(dirname "$0")/../package/tailscale-bin/tailscale-bin.mk" | tr -d '[:space:]')"
[ -n "$TS_EXPECT" ] \
  || { echo "::error::could not read TAILSCALE_BIN_VERSION from package/tailscale-bin/tailscale-bin.mk — this assertion has nothing to compare against"; exit 1; }
TS_LINE="$(grep -ao 'rasputin-tailscale: .*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
if [ "$tsrep" != 1 ] || [ -z "$TS_LINE" ]; then
  echo "::error::no 'rasputin-tailscale:' report reached the serial console in ${TS_AT}s — nothing checked that tailscaled runs. Check rasputin-tailscale-report.service is still in the overlay and enabled in post-build.sh."
  exit 1
fi
echo "tailscale report: $TS_LINE"
case "$TS_LINE" in
  *" state=active "*) ;;
  *) echo "::error::tailscaled is not active on the booted image — mesh enrollment would be dead on every node: $TS_LINE"; exit 1 ;;
esac
case "$TS_LINE" in
  *" daemon=${TS_EXPECT} "*) ;;
  *) echo "::error::the running tailscaled did not report version ${TS_EXPECT} over its LocalAPI (tailscale version --daemon): $TS_LINE"; exit 1 ;;
esac
case "$TS_LINE" in
  *" binary=${TS_EXPECT}") ;;
  *) echo "::error::/usr/sbin/tailscaled --version did not report ${TS_EXPECT} (binary=none means the path does not exec — a symlink loop shows up exactly like this): $TS_LINE"; exit 1 ;;
esac
echo "tailscaled active, daemon and /usr/sbin/tailscaled both report ${TS_EXPECT}"

# The booted kernel is one this rootfs was built for (geekdojo/geekdojo-brain#807).
# A fresh flash boots its own kernel, so this is the baseline: it proves the
# image's /usr/lib/rasputin/kernel-ids describes the kernel the image ships,
# which is what makes the same verdict meaningful after an update (the update
# smoke asserts it there). No verdict fails like a MISMATCH does: silence means
# nothing checked.
KM_LINE="$(grep -ao 'rasputin-kernel-match: .*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
if [ "$kmrep" != 1 ] || [ -z "$KM_LINE" ]; then
  echo "::error::no 'rasputin-kernel-match:' verdict reached the serial console in ${KM_AT}s — nothing checked that the kernel matches the rootfs. Check rasputin-kernel-match.service is in the overlay and enabled in post-build.sh."
  exit 1
fi
case "$KM_LINE" in
  "rasputin-kernel-match: MATCH "*) echo "kernel matches the rootfs: $KM_LINE" ;;
  *) echo "::error::the booted kernel is not one this rootfs was built for, on a FRESH flash — post-build.sh baked a kernel-ids list that does not describe the kernel post-image.sh staged: $KM_LINE"; exit 1 ;;
esac

# The seal key (geekdojo/geekdojo-brain#803, TC-803-26). A fresh control plane
# has neither a key nor store data, so rasputin-seal-key.service creates the
# key and writes one "rasputin-seal-key:" line to /dev/kmsg. It is ordered
# before the api, so by the time /healthz answered the line was already written:
# no arrival poll. A missing line fails like a wrong one: silence means nothing
# created the key. The /healthz and soak checks below are what show its gate
# does not hold a fresh node down.
SK_LINE="$(grep -ao 'rasputin-seal-key: .*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
case "$SK_LINE" in
  "rasputin-seal-key: outcome=created "*) echo "seal key created at boot: ${SK_LINE%% reason=*}" ;;
  "") echo "::error::no 'rasputin-seal-key:' line reached the serial console — nothing created the secrets store's seal key on a fresh control plane. Check rasputin-seal-key.service is in the overlay and enabled."; exit 1 ;;
  *) echo "::error::the seal-key oneshot did not create a key on a FRESH control plane: $SK_LINE"; exit 1 ;;
esac

# The store initialised itself (geekdojo/geekdojo-brain#804, TC-804-23). A
# freshly flashed control plane's store starts on an empty data directory, so
# its first start must end in exactly one "outcome=initialised" line and no
# "outcome=failed" line. A missing line fails like a wrong one: silence means
# the store never started, or nothing recorded what its first start did.
SI_LINE="$(grep -ao 'rasputin-store-init: .*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
if grep -aq 'rasputin-store-init: outcome=failed' "$CONSOLE_LOG"; then
  echo "::error::the secrets store's self-init FAILED on a fresh control plane, and that store will refuse to unseal on every later start: $(grep -ao 'rasputin-store-init: outcome=failed.*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
  exit 1
fi
case "$SI_LINE" in
  "rasputin-store-init: outcome=initialised "*) echo "secrets store initialised itself at first start: ${SI_LINE%% reason=*}" ;;
  "") echo "::error::no 'rasputin-store-init:' line reached the serial console in ${SI_AT}s — the secrets store's first start was never recorded on a fresh control plane: the api did not mint its leaf and restart the store, the store never started, or openbao.service lost its outcome hooks."; exit 1 ;;
  *) echo "::error::the secrets store's first start on a fresh control plane did not report outcome=initialised: $SI_LINE"; exit 1 ;;
esac

# The api reports the store ready (geekdojo/geekdojo-brain#834), polled above,
# before the kill. store_ready_report names the fact that never came true: the
# check never ran, the sign-in failed, or the store never read ready.
rm -f "$SR_JAR"
store_ready_report "$SR_STAGE" "$SR_REASON" "$SR_RC" "$SR_LAST" "$SR_AT" || exit 1
# The store's provisioner (geekdojo/geekdojo-brain#805, TC-805-35). After the
# store's first start the provisioner runs once, and this release's
# provision.tsv lists nothing, so its one line is outcome=unchanged. A failed
# line fails the image; so does silence: then nothing provisioned, or nothing
# recorded that it did.
PV_LINE="$(grep -ao 'rasputin-store-provision: outcome=.*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
if grep -aq 'rasputin-store-provision: outcome=failed' "$CONSOLE_LOG"; then
  echo "::error::the secrets store's provisioner FAILED on a fresh control plane: $(grep -ao 'rasputin-store-provision: outcome=failed.*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
  exit 1
fi
# Nor may systemd have failed a provisioner job with result 'dependency'
# (ledger F-805-28). On a fresh flash the store is condition-skipped until the
# api mints its leaves; a provisioner job queued beside that skipped start
# fails its Requisite= and prints this on every first boot, even though a
# later run of the store still provisions and reports outcome=unchanged.
PV_DEP="Dependency failed for .*Secrets store provisioner|rasputin-store-provision\\.service: Job .* failed with result 'dependency'"
if grep -aqE "$PV_DEP" "$CONSOLE_LOG"; then
  echo "::error::systemd failed a secrets store provisioner job with result 'dependency' on a fresh control plane (F-805-28): something queued rasputin-store-provision.service beside a store start that never reached READY — openbao.service must start it only from its last ExecStartPost=: $(grep -aoE "$PV_DEP" "$CONSOLE_LOG" | tr -d '\r' | head -1)"
  exit 1
fi
case "$PV_LINE" in
  "rasputin-store-provision: outcome=unchanged "*) echo "secrets store provisioner ran after the store's first start: ${PV_LINE%% reason=*}" ;;
  "") echo "::error::no 'rasputin-store-provision: outcome=' line reached the serial console in ${SI_AT}s — the store's provisioner never ran after its first start, or openbao.service lost the ExecStartPost= that starts rasputin-store-provision.service."; exit 1 ;;
  *) echo "::error::the secrets store's provisioner did not report outcome=unchanged on a fresh control plane: $PV_LINE"; exit 1 ;;
esac

[ "$api" = 1 ] \
  || { echo "::error::rasputin-api never answered /healthz on :80 on the controlplane boot — unit failed to start, RASPUTIN_HTTP_ADDR regressed, or networking broke; see console artifact"; exit 1; }
[ "$ui" = 1 ] \
  || { echo "::error::GET / on :80 returned neither the web UI nor an HTTPS redirect — RASPUTIN_UI_DIR contents missing from the api tarball or the bootstrap surface regressed"; exit 1; }
[ "$soak" = 1 ] \
  || { echo "::error::api did not survive the 70s uptime soak — watchdog kill loop or crash; check console for 'Watchdog timeout' / SIGABRT"; exit 1; }
if grep -q "Watchdog timeout" "$CONSOLE_LOG"; then
  echo "::error::systemd watchdog killed a rasputin unit during the smoke — sd_notify petting regressed (see the v0.4.3 sdnotify package)"; exit 1
fi
echo "api healthz + web UI + 70s uptime soak confirmed over hostfwd"

# At-rest file modes on the persistent partition (geekdojo/geekdojo-brain#494,
# gate 7). rasputin-atrest-audit.service checks every path the inventory
# declares and sweeps the trees that hold nothing but credentials, then reports
# one verdict line. Both the unit and the inventory have said all along that
# this smoke greps that verdict "so a change that widens a mode fails a release
# build instead of shipping". Until now nothing did: the audit ran on every
# boot, printed its verdict, and no build ever read it.
#
# Read off the console rather than over a hostfwd because the audit has no
# port. It is a boot-time shell script, the smoke has no shell into the guest,
# and only /dev/kmsg is mirrored to the serial console (journald's output is
# not) — the same channel firstboot and the hostname unit are asserted through
# above. Exactly ONE "rasputin-atrest:" line arrives that way: the verdict. The
# audit's per-finding lines go to its stdout, which systemd captures into the
# guest's journal, so they are not readable from here. The check below is
# nevertheless written to refuse ANY FAIL line among whatever it finds, rather
# than to trust the first line it sees, so it stays correct if that changes.
#
# THREE OUTCOMES, AND ONLY ONE OF THEM IS GREEN.
#
#   PASS checked=N   the only pass, and N must be non-zero.
#   FAIL ...         a declared path is not its declared mode, owner or group,
#                    grants access the inventory does not declare, a swept file
#                    is group- or world-accessible, a mode, owner or group could
#                    not be read, or the inventory itself was unreadable.
#   nothing          the verdict never arrived.
#
# The absent case FAILS AS LOUDLY AS A FAIL LINE, and that is the whole point
# of splitting it out. A boot where the unit was masked, renamed, dropped from
# multi-user.target, ordered behind something that never started, or removed
# from the overlay altogether produces no verdict at all — and a bare
# `grep -q FAIL || pass` would read that silence as success, leaving a green
# build over a machine nobody checked. That is the failure mode the audit's own
# header warns about: a verdict that said PASS while a key sat at 0644 would be
# worse than having no audit at all, and so would a smoke that accepted no
# verdict as one.
#
# A PASS over checked=0 is refused for the same reason. It is what an empty or
# fully-commented inventory produces: a real PASS line, over nothing.
#
# The captured line is echoed into the failure output on purpose. The verdict
# carries the first failing path and its actual mode, so a red build says WHICH
# file widened rather than only that an assertion failed.
#
# Read back AFTER the kill, so qemu is no longer appending to the file while
# this greps it (the arrival was polled above, before the kill).
ATREST_LINES="$(grep -o 'rasputin-atrest: .*' "$CONSOLE_LOG" | tr -d '\r')"
if [ "$atrest" != 1 ] || [ -z "$ATREST_LINES" ]; then
  echo "::error::no 'rasputin-atrest:' verdict reached the serial console in ${ATREST_AT}s — the at-rest mode audit never reported, so NOTHING checked the modes on the persistent partition on this boot. Treated exactly like a FAIL: check that rasputin-atrest-audit.service is still in the overlay, still WantedBy=multi-user.target, not masked, and that its ordering (After=rasputin-api.service) did not leave it behind a unit that never started; check too that the verdict still goes to /dev/kmsg, since journald's output does not reach this console."
  echo "----- any atrest-related console lines (if one appears here, the verdict's own wording changed and this assertion has drifted from rasputin-atrest-audit.sh) -----"
  atrest_ctx="$(grep -nE "atrest" "$CONSOLE_LOG" | tail -20)"
  echo "${atrest_ctx:-(not one line mentions the audit — the unit did not run at all)}"
  exit 1
fi
if printf '%s\n' "$ATREST_LINES" | grep -q "rasputin-atrest: FAIL"; then
  echo "::error::the at-rest mode audit FAILED on the booted machine — a path on the persistent partition is not the mode, owner or group /usr/lib/rasputin/atrest/inventory declares for it, or a swept tree holds a group/world-accessible file. The verdict below carries the count and the FIRST offending path with its actual mode; the remaining findings are printed on the audit's stdout, which systemd captures into the guest's journal and which therefore does NOT reach this console — reproduce them with test/atrest-modes-test.sh or on a node. Either the mode regressed or the inventory is out of date — do not widen the inventory to match a widened file."
  printf '%s\n' "$ATREST_LINES" | sed 's/^/  /'
  exit 1
fi
ATREST_CHECKED="$(printf '%s\n' "$ATREST_LINES" \
  | sed -n 's/^rasputin-atrest: PASS checked=\([0-9][0-9]*\).*$/\1/p' | head -1)"
case "$ATREST_CHECKED" in
  ''|0)
    echo "::error::the at-rest verdict is neither a usable PASS nor a FAIL: '$(printf '%s\n' "$ATREST_LINES" | head -1)'. A PASS must carry checked=N with N greater than zero — 'PASS checked=0' is what an empty or entirely-commented inventory reports, a green verdict over nothing. If the verdict's wording changed, this assertion and rasputin-atrest-audit.sh have drifted apart."
    printf '%s\n' "$ATREST_LINES" | sed 's/^/  /'
    exit 1 ;;
esac
echo "at-rest modes audited clean on the booted machine (PASS checked=$ATREST_CHECKED)"

# ------------------------------------------------- growpart leg (#853) --------
# A fresh flash on a medium larger than the image: rasputin-growpart extends the
# persistent partition and reboots, and the next boot's x-systemd.growfs grows
# the filesystem. The provisioning boot's journal must survive that reboot, so
# its seal-key `created` and firstboot lines are readable as `journalctl -b -1`
# (geekdojo/geekdojo-brain#853). Before the fix the next boot's flush rotated the
# provisioning boot's journal on a clock-floor jump and the vacuum, measuring the
# still-512M filesystem, deleted the archive.
#
# The copy taken before the main boot is grown by 8G and booted with:
#   -rtc base=2000-01-01  no real time from the RTC, as on a Pi, so the clock
#                         floor is the only clock source;
#   restrict=on           the guest cannot reach NTP, so timesyncd never syncs
#                         and the kernel never writes the RTC back. The SSH
#                         forward still works: restrict does not affect hostfwd.
# QEMU reboots itself on the guest's reboot. The leg waits on facts: the main
# QEMU having exited (it holds SSH_PORT), then `already-full` in growpart.log,
# which only the post-grow boot writes, then that boot's seal-key outcome line,
# which is not ordered against growpart. QEMU's BOOT_BUDGET bounds the process.

# The main QEMU was killed above; its exit frees SSH_PORT for the leg's forward.
wait "$QPID" 2>/dev/null
QPID=""
truncate -s +8G "$GROW_IMG" \
  || { echo "::error::could not grow $GROW_IMG by 8G for the growpart leg"; exit 1; }
if [ "$ARCH" = amd64 ]; then
  cp "$OVMF_VARS" "$WORK/grow-vars.fd" \
    || { echo "::error::could not copy the OVMF vars for the growpart leg"; exit 1; }
  VARS_FD="$WORK/grow-vars.fd"
fi
# die_if_qemu_gone reads QPID and CONSOLE_LOG: from here on they are the leg's.
# The main boot's console stays where the workflow uploads it from.
CONSOLE_LOG="$WORK/grow-console.log"
: > "$CONSOLE_LOG"
qemu_exec "$ARCH" "$GROW_IMG" "$BOOT_BUDGET" "$CONSOLE_LOG" \
  "restrict=on,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -rtc base=2000-01-01T00:00:00 &
QPID=$!
echo "growpart leg: booting $GROW_IMG (+8G) with the RTC at 2000-01-01 and no route out"

GROW_LAST=""   # growpart.log as of its last successful read
# leg_poll WHAT CMD — run CMD in the guest until it succeeds. If QEMU exits
# first: status 124 is `timeout` reaching BOOT_BUDGET, reported as WHAT never
# arriving; any other status is QEMU stopping on its own (die_if_qemu_gone).
leg_poll() {
  while :; do
    _gl=$(ssh_guest 'cat /var/lib/rasputin/growpart.log' 2>/dev/null) && GROW_LAST=$_gl
    ssh_guest "$2" >/dev/null 2>&1 && return 0
    if qemu_gone; then
      wait "$QPID"; _st=$?
      if [ "$_st" = 124 ]; then
        echo "::error::no $1 before qemu's budget expired"
        echo "----- growpart.log as last read -----"; printf '%s\n' "${GROW_LAST:-(never read)}"
        echo "----- the grow boot's console (whole file) -----"; cat "$CONSOLE_LOG" || true
        exit 1
      fi
      die_if_qemu_gone "$1"
    fi
    sleep 2
  done
}
leg_poll "\`already-full\` line in growpart.log" "grep -q already-full /var/lib/rasputin/growpart.log"
leg_poll "\`rasputin-seal-key: outcome=\` line in the post-grow boot's journal" \
  "journalctl -b 0 -o cat --no-pager | grep -qF 'rasputin-seal-key: outcome='"
echo "growpart leg: the post-grow boot is up (already-full in growpart.log, seal-key outcome logged)"

# leg_fail SENTENCE — one ::error:: naming the fact, then what explains it.
leg_fail() {
  echo "::error::growpart leg ($ARCH): $1"
  echo "----- journalctl --header -----"; ssh_guest 'journalctl --header --no-pager' 2>&1 || true
  echo "----- ls of the journal directory -----"; ssh_guest 'ls -la /var/log/journal/*/' 2>&1 || true
  echo "----- growpart.log -----"; ssh_guest 'cat /var/lib/rasputin/growpart.log' 2>&1 || true
  exit 1
}

# The clock margin, always recorded. Rotation needs boot 2's first entry dated
# earlier than boot 1's last, so margin > 0 is the condition this leg relies on.
B1_LAST=$(ssh_guest "journalctl -b -1 -n 1 -o export --no-pager | sed -n 's/^__REALTIME_TIMESTAMP=//p'" 2>/dev/null)
B2_FIRST=$(ssh_guest "journalctl -b 0 -o export --no-pager | sed -n 's/^__REALTIME_TIMESTAMP=//p' | head -1" 2>/dev/null)
case "$B1_LAST$B2_FIRST" in
  ''|*[!0-9]*) MARGIN="unknown" ;;
  *) MARGIN=$((B1_LAST - B2_FIRST)) ;;
esac
[ -n "$B1_LAST" ] && [ -n "$B2_FIRST" ] || MARGIN="unknown"
echo "growpart leg ($ARCH) clock: boot 1 last __REALTIME_TIMESTAMP=${B1_LAST:-none} boot 2 first __REALTIME_TIMESTAMP=${B2_FIRST:-none} margin (boot 1 last - boot 2 first)=${MARGIN}us"

# (a) growpart grew the partition, rebooted, and found it full on the next boot.
ssh_guest "awk '\$2 == \"grown:\" { g = 1 } g && \$2 == \"already-full:\" { a = 1 } END { exit !a }' /var/lib/rasputin/growpart.log" \
  || leg_fail "growpart.log does not hold a grown: line followed by an already-full: line"
echo "growpart leg (a): growpart.log holds grown: then already-full:"
# (b) the journal holds the provisioning boot and this one. journalctl has no
# --no-legend, so the boot rows are counted by their shape: an index, then a
# 32-hex boot ID.
NBOOTS=$(ssh_guest "journalctl --list-boots --no-pager | grep -cE '^ *-?[0-9]+ [0-9a-f]{32} '" 2>/dev/null | tr -d ' ')
[ "${NBOOTS:-0}" -ge 2 ] 2>/dev/null \
  || leg_fail "journalctl --list-boots shows ${NBOOTS:-no} boot(s), expected at least 2: the provisioning boot's journal is gone"
echo "growpart leg (b): journalctl --list-boots shows $NBOOTS boots"
# (c) the provisioning boot's seal-key created line, exactly once.
NCREATED=$(ssh_guest "journalctl -b -1 -o cat --no-pager | grep -cF 'rasputin-seal-key: outcome=created'" 2>/dev/null)
[ "$NCREATED" = 1 ] \
  || leg_fail "journalctl -b -1 holds 'rasputin-seal-key: outcome=created' ${NCREATED:-0} times, expected exactly 1"
echo "growpart leg (c): journalctl -b -1 holds rasputin-seal-key: outcome=created exactly once"
# (d) firstboot's outcome from the provisioning boot.
ssh_guest "journalctl -b -1 -o cat --no-pager | grep -qF 'rasputin-firstboot: provisioning complete'" \
  || leg_fail "journalctl -b -1 does not hold 'rasputin-firstboot: provisioning complete'"
echo "growpart leg (d): journalctl -b -1 holds rasputin-firstboot: provisioning complete"
# (e) the post-grow boot found the key and left it alone.
ssh_guest "journalctl -b 0 -o cat --no-pager | grep -qF 'rasputin-seal-key: outcome=untouched'" \
  || leg_fail "journalctl -b 0 does not hold 'rasputin-seal-key: outcome=untouched': $(ssh_guest "journalctl -b 0 -o cat --no-pager | grep -F 'rasputin-seal-key: outcome='" 2>&1)"
echo "growpart leg (e): journalctl -b 0 holds rasputin-seal-key: outcome=untouched"
# (f) the floor rotation happened, so this run exercised the deletion path.
ssh_guest "journalctl -b 0 --no-pager | grep -qF 'Realtime clock jumped backwards'" \
  || leg_fail "journalctl -b 0 has no 'Realtime clock jumped backwards' line: the clock-floor rotation was not reproduced (boot 1 last __REALTIME_TIMESTAMP=${B1_LAST:-none}, boot 2 first __REALTIME_TIMESTAMP=${B2_FIRST:-none}, margin ${MARGIN}us), so this run did not exercise the deletion path"
echo "growpart leg (f): journalctl -b 0 holds Realtime clock jumped backwards"
# (g) the new ordering put the grow before the bind mount.
GROWFS_EXIT=$(ssh_guest 'systemctl show -P ExecMainExitTimestampMonotonic systemd-growfs@var-lib-rasputin.service' 2>/dev/null | tr -d '\r')
STORE_START=$(ssh_guest 'systemctl show -P ExecMainStartTimestampMonotonic rasputin-journal-store.service' 2>/dev/null | tr -d '\r')
case "$GROWFS_EXIT:$STORE_START" in
  *[!0-9:]*|:*|*:|0:*|*:0) leg_fail "systemd-growfs@var-lib-rasputin.service ExecMainExitTimestampMonotonic=${GROWFS_EXIT:-none} and rasputin-journal-store.service ExecMainStartTimestampMonotonic=${STORE_START:-none} are not both set: one of them did not run on the post-grow boot" ;;
esac
[ "$GROWFS_EXIT" -le "$STORE_START" ] \
  || leg_fail "systemd-growfs@var-lib-rasputin.service exited at ${GROWFS_EXIT}us monotonic, after rasputin-journal-store.service started its bind mount at ${STORE_START}us: the journal store is not ordered after the grow"
echo "growpart leg (g): growfs exited at ${GROWFS_EXIT}us, before the journal store's bind mount started at ${STORE_START}us"
# (h) the edge made no ordering cycle.
CYCLE=$(ssh_guest "journalctl -b 0 -o cat --no-pager | grep -i 'ordering cycle'" 2>/dev/null)
[ -z "$CYCLE" ] \
  || leg_fail "journalctl -b 0 logs an ordering cycle: $CYCLE"
echo "growpart leg (h): journalctl -b 0 has no ordering cycle line"
# (i) the grow waited for the api's READY=1 in the provisioning boot. systemd's
# "Started" entry (SD_MESSAGE_UNIT_STARTED) for a Type=notify unit is logged
# when READY=1 arrives; growpart's "Starting" (SD_MESSAGE_UNIT_STARTING) is
# logged when its start job runs. Both are boot -1's, so their monotonic stamps
# compare.
leg_mono() {
  ssh_guest "journalctl -b -1 -o export --no-pager UNIT=$1 MESSAGE_ID=$2 | sed -n 's/^__MONOTONIC_TIMESTAMP=//p' | head -1" 2>/dev/null | tr -d '\r'
}
API_STARTED=$(leg_mono rasputin-api.service 39f53479d3a045ac8e11786248231fbf)
GROW_STARTING=$(leg_mono rasputin-growpart.service 7d4958e842da4a758f6c1cdc7b36dcc5)
case "$API_STARTED" in
  ''|*[!0-9]*) leg_fail "journalctl -b -1 has no UNIT=rasputin-api.service \"Started\" entry (MESSAGE_ID 39f53479d3a045ac8e11786248231fbf), so the api never sent READY=1 in the provisioning boot (growpart Starting at ${GROW_STARTING:-none}us monotonic)" ;;
esac
case "$GROW_STARTING" in
  ''|*[!0-9]*) leg_fail "journalctl -b -1 has no UNIT=rasputin-growpart.service \"Starting\" entry (MESSAGE_ID 7d4958e842da4a758f6c1cdc7b36dcc5), so growpart's start in the provisioning boot was not recorded (api Started at ${API_STARTED}us monotonic)" ;;
esac
[ "$API_STARTED" -lt "$GROW_STARTING" ] \
  || leg_fail "in the provisioning boot rasputin-api.service was Started at ${API_STARTED}us monotonic, not before rasputin-growpart.service was Starting at ${GROW_STARTING}us: the grow's reboot is not ordered after the api's READY=1"
echo "growpart leg (i): in boot -1 the api was Started at ${API_STARTED}us, before growpart was Starting at ${GROW_STARTING}us"
# Where the store's first-start outcomes landed, recorded and not asserted:
# the bench skill's SST-01 init row has to read the boot they are in.
for _tag in rasputin-store-init rasputin-store-provision; do
  for _b in -1 0; do
    _lines=$(ssh_guest "journalctl -b $_b -o cat --no-pager | grep -F '$_tag: outcome='" 2>/dev/null | tr -d '\r')
    _n=$(printf '%s' "$_lines" | grep -c . || true)
    echo "growpart leg ($ARCH) record: boot $_b holds $_n '$_tag: outcome=' line(s)$(printf '%s\n' "$_lines" | sed -n '1s/ reason=.*//p' | sed 's/^/, first: /')"
  done
done
echo "growpart leg ($ARCH): the provisioning boot's journal survived the grow reboot"
