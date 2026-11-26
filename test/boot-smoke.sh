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
# api's report, the wait and the post-kill report.
# shellcheck source=test/lib/store-ready.sh
. "$(dirname "$0")/lib/store-ready.sh"
# The first-run sign-in through the console (geekdojo/geekdojo-brain#993):
# the signin.py wrapper and the facts it waits on. Its session is the one the
# store and identity reports are read with.
# shellcheck source=test/lib/smoke-signin.sh
. "$(dirname "$0")/lib/smoke-signin.sh"
# The identity service's readiness (geekdojo/geekdojo-brain#974): the realm
# wait and the verdict on the api's identity report.
# shellcheck source=test/lib/identity-ready.sh
. "$(dirname "$0")/lib/identity-ready.sh"
LIBDIR="$(dirname "$0")/lib"

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
# The first-run sign-in (geekdojo/geekdojo-brain#993, amd64 only), after the
# realm wait, waits on three facts, each polled 2s apart and ended the moment
# it holds:
#   DOOR_TRIES  the console's /api/auth/signup reaching the door's themed
#               registration form: converge has applied the console client's
#               redirect URI and opened registration. Converge is submitted at
#               a scheduler check every 60s once migrations are applied, so
#               the ceiling is 60 reads, 120s: one check interval, the run and
#               a margin.
#   SYNC_TRIES  the guest's clock-sync marker, then the realm offering
#               CONFIGURE_TOTP (converge enables it only on a run that read
#               the marker): 30 reads, 60s, normally the first.
#   GRANT_TRIES GET /api/auth/me on the authenticator enrolment's session
#               answering 401: the grant ends the account's sessions (C23).
#               30 reads, 60s, normally within a few.
# Each signin.py call is bounded by --timeout 20 per HTTP call; a code
# sign-in waits at most 30s for the next TOTP step; a credential post the door
# answers busy (one post per source, freed by its next drain pass) is posted
# again each second for at most 30s, normally a second or two; and an
# enrolment the console locks while the converge that ends first run applies
# the sign-in rules (423 signin_rules_applying) asks again every 2s for at
# most 120s, one scheduler interval and the run. Projected from SP-1 the
# phase adds about 263s on a fresh image (base 154 + fresh ready 22.0 + verb
# subset 87.1; identity-evidence/959/index.md:33,127); its ceilings (120 + 60
# + 60 plus the verbs) sit on top of the polls above, which by then end on
# their first read, so a stuck fact is reported by its own ::error:: line
# rather than by QEMU's 900s bound killing the guest under the script.
# The arm64 identity masks (prepare_arm64 says why); the growpart leg's boot
# carries them too.
ARM64_ID_MASKS="systemd.mask=keycloak.service systemd.mask=keycloak-db.service"
BOOT_BUDGET=900 ; MU_TRIES=120 ; FB_TRIES=60 ; API_TRIES=48 ; HS_TRIES=60 ; ATREST_TRIES=60 ; TS_TRIES=30 ; KM_TRIES=30 ; SI_TRIES=30 ; SR_TRIES=30
DOOR_TRIES=60 ; SYNC_TRIES=30 ; GRANT_TRIES=30
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
  # The sign-in's synthetic credentials, keys and session jars (#993).
  rm -rf "$KEY" "$KEY.pub" "$GROW_IMG" "$WORK/signin"
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

  # The SHIPPED cmdline, verbatim, plus exactly three harness additions — so a
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
  SHIPPED_CMDLINE="$(tr -d '\n' < "$WORK/cmdline.txt")"
  #   $ARM64_ID_MASKS — the identity service and its database, masked: arm64
  #     runs under TCG here, and identity never runs emulated (testing.md,
  #     Bryce 2026-11-08; geekdojo/geekdojo-brain#974). The arm64 identity
  #     runtime is proved on the bench. Each cmdline echo line shows both.
  CMDLINE="$SHIPPED_CMDLINE systemd.log_target=kmsg console=ttyAMA0,115200 $ARM64_ID_MASKS"
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
  # correct — this only affects emulation. amd64 runs under KVM only
  # (qemu_exec refuses to start without a usable /dev/kvm; release.yml's udev
  # step opens it on the runner): the identity service's JVM crashes under
  # amd64 TCG (geekdojo/geekdojo-brain#974).
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
api=0 ui=0 https=0 NSUDP="" NSTCP="" HS_FIRST=""
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
    # CP nameserver (ADR-0004 §3/§8): ask the guest's own :53 for the cluster
    # zone apex over BOTH transports, via the hostfwd on the qemu line.
    # Collected here, while the VM is still running: everything below the
    # qemu kill talks to a dead machine.
    #
    # Queried rather than grepped from the console because the api logs to the
    # journal — its "nameserver authoritative for ..." line is not on the serial
    # console. Asking is the stronger check anyway: it proves the
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
# WantedBy=multi-user.target and ordered After=rasputin-api.service and
# rasputin-agent.service, so its verdict can land well after every assertion
# above: it does not start until the agent has (and, on a controlplane boot,
# the api), and it audits the files they wrote.
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

# The identity service is ready (geekdojo/geekdojo-brain#974), and the first
# account is made and signed in through the console (#993), amd64 only: the
# arm64 smoke masks both identity units, see prepare_arm64. In this order, each
# read before the kill and asserted after it:
#   (a) the realm wait (test/lib/identity-ready.sh): realm rasputin's
#       discovery document answering 200 over mutual TLS with the api's
#       identity client leaf, stopped early by a failed unit or the start-hold
#       record, and bounded only by QEMU's budget through die_if_qemu_gone;
#   the first-run sign-in (below), whose password-and-code sign-in's session
#       is the jar every report after it is read with;
#   the store's readiness (geekdojo/geekdojo-brain#834): its only report is
#       GET /api/alerts, which needs a session, where a store in any state but
#       ready raises a "secret-store:" alert; polled once the store-init line
#       is in, since until then there is nothing to ask about;
#   (b) one GET /api/alerts on that session: no identity: id. One read is
#       enough, because the api's monitor computes on each read.
# The image facts (c), the guest checks (d), the memory record (e) and the
# role gate (f) follow below, after the facts reads.
#
# The SR_ variables are set before the gate because this script runs under
# set -u, and the report reads all of them on every path.
SR_STAGE="" SR_REASON="" SR_RC="" SR_LAST="" SR_AT=""
SG_DIR="$WORK/signin"
SR_JAR="$SG_DIR/admin.jar"
MESH_CA_PEM="$SG_DIR/mesh-ca.pem"
CONSOLE_HOST="${CLUSTER_ID}.local"
APP_HOST="signin.${CLUSTER_ID}.internal"
# smoke_fetch — store_ready_wait's FETCH: prints the code and the body's path.
# The console's own name, its certificate checked against the cluster's CA.
smoke_fetch() {
  rm -f "$WORK/alerts.body"
  printf '%s %s\n' "$(curl -s --connect-to "${CONSOLE_HOST}:443:127.0.0.1:${HTTPS_PORT}" --cacert "$MESH_CA_PEM" \
    -b "$SR_JAR" --max-time 5 -o "$WORK/alerts.body" -w '%{http_code}' \
    "https://${CONSOLE_HOST}/api/alerts" || true)" "$WORK/alerts.body"
}
# me_status — GET /api/auth/me's status on the authenticator enrolment's
# session, for the grant wait.
me_status() {
  curl -s -o /dev/null -w '%{http_code}' --connect-to "${CONSOLE_HOST}:443:127.0.0.1:${HTTPS_PORT}" \
    --cacert "$MESH_CA_PEM" -b "$SG_DIR/enrol.jar" --max-time 5 "https://${CONSOLE_HOST}/api/auth/me" || true
}
sync_probe() { ss_sync_probe ssh_guest; }
grant_probe() { ss_grant_probe me_status; }

# The first-run sign-in (geekdojo/geekdojo-brain#993, issue TC-01 to TC-03):
# the customer's path, through the console at https://smoke1.local and its
# home door https://sso-smoke1.local, every name sent to the HTTPS hostfwd
# with its certificate checked against the cluster's CA. The account is made
# on the door's pages; nothing enrols through the Admin API. Each step needs
# the one before it, so the first failure stops the sequence: SG_FAIL names
# it, and the assertion after the kill reports it.
#
# Run here: create-account (and its recovery codes); the authenticator app and
# a passkey through #1150's launcher, each after a fresh sign-in; the grant;
# sign-out; password and code, passkey alone, and a recovery code; the
# password alone refused; and the WebAuthn negatives at the home door, last.
# Not run here, by decision (dev-records 993 README, 2026-11-25):
# pkce-wrong-verifier and pkce-absent, because the api holds the PKCE verifier
# and a client cannot send a wrong or absent one (S256 and the exchange are
# covered in rasputin-control-plane's identity/client/exchange_test.go and
# converge/backchannel_test.go, and by SP-1 against stock Keycloak); and
# no-app-access, which needs an app-door client, and so a full app-door
# sign-in, with #1027. The app door's own name and certificate are checked
# through its discovery document instead.
IR_RC="" IR_LAST="" IR_SECONDS="" ID_REPORT=""
SG_FAIL="" SG_AT="" SG_ROLES="" SG_RPID="" SG_RPID2="" SG_NEG="" APP_CODE="" APP_ISSUER=""
SS_SIGNIN="$LIBDIR/signin.py" SS_STATE="$SG_DIR/state" SS_DOORS="$SG_DIR/doors.json" SS_CA="$MESH_CA_PEM"
SS_CONNECT="127.0.0.1:${HTTPS_PORT}" SS_LABEL=owner
# sg_fail SENTENCE — the first failure, kept; every later step is skipped.
sg_fail() { [ -n "$SG_FAIL" ] || SG_FAIL=$1; }
# sg STEP... — one smoke_signin step, run only while nothing has failed.
sg() { [ -z "$SG_FAIL" ] || return 1; smoke_signin "$@" || { sg_fail "signin.py $* did not pass"; return 1; }; }
# sg_field KEY — KEY's value in the last signin.py line, e.g. rp_id or roles.
sg_field() { printf '%s\n' "$SS_LINE" | tr ' ' '\n' | sed -n "s/^$1=\\(.*\\);\$/\\1/p" | head -1; }
sign_in_sequence() {
  rm -rf "$SG_DIR"
  (umask 077 && mkdir -p "$SS_STATE") || { sg_fail "the sign-in's state directory could not be made"; return; }
  chmod 700 "$SS_STATE"
  ssh_guest 'cat /var/lib/rasputin/trust/mesh-ca.pem' </dev/null >"$MESH_CA_PEM" 2>/dev/null && [ -s "$MESH_CA_PEM" ] \
    || { echo "::error::the cluster's CA /var/lib/rasputin/trust/mesh-ca.pem could not be read over SSH"; sg_fail "no mesh CA"; return; }
  cat >"$SS_DOORS" <<EOF
{"home": {"origin": "https://sso-${CONSOLE_HOST}", "realm": "rasputin", "client_id": "rasputin-console",
          "redirect_uri": "https://${CONSOLE_HOST}/api/auth/callback",
          "console": {"origin": "https://${CONSOLE_HOST}", "methods_route": "/api/me/sign-in-methods",
                      "methods": {"totp": "authenticator_app", "passkey": "passkey",
                                  "passkey-2fa": "security_key", "recovery-codes": "recovery_codes"}}},
 "app": {"origin": "https://${APP_HOST}", "realm": "rasputin", "client_id": "no-app-client-until-1027",
         "redirect_uri": "https://app.${CLUSTER_ID}.internal/callback"}}
EOF
  # The app door is named only as the negatives' wrong origin and RP ID.
  ss_wait "the console's sign-up reaching the door's registration form" "$DOOR_TRIES" 2 ss_door_probe die_if_qemu_gone \
    || { sg_fail "the door never showed its registration form"; return; }
  sg create-account || return
  case ",$(sg_field roles)," in *,admin,*) echo "::error::the account was made an administrator at creation, before any second step: $SS_LINE"; sg_fail "admin at creation"; return ;; esac
  ss_wait "the clock-sync marker, then the realm offering CONFIGURE_TOTP" "$SYNC_TRIES" 2 sync_probe die_if_qemu_gone \
    || { sg_fail "the authenticator app was never offered"; return; }
  sg enrol totp --jar "$SG_DIR/enrol.jar" || return
  ss_wait "the grant ending the enrolment's console session" "$GRANT_TRIES" 2 grant_probe die_if_qemu_gone \
    || { sg_fail "the grant never ended the enrolment's session"; return; }
  sg enrol passkey || return
  SG_RPID=$(sg_field rp_id)
  sg sign-out || return
  sg sign-in password-totp --jar "$SR_JAR" || return
  SG_ROLES=$(sg_field roles)
  sg sign-in passkey || return
  SG_RPID2=$(sg_field rp_id)
  sg negative admin-password-alone || return
  sg sign-in recovery-code || return
  rm -f "$WORK/app-door.json"
  APP_CODE=$(curl -s --max-time 10 --connect-to "${APP_HOST}:443:127.0.0.1:${HTTPS_PORT}" --cacert "$MESH_CA_PEM" \
    -o "$WORK/app-door.json" -w '%{http_code}' "https://${APP_HOST}/realms/rasputin/.well-known/openid-configuration" || true)
  APP_ISSUER=$(jq -r '.issuer // empty' "$WORK/app-door.json" 2>/dev/null)
  for n in bad-origin bad-rpid no-up no-uv bad-signature bad-challenge replay; do
    sg negative "$n" || return
    SG_NEG="$SG_NEG $n"
  done
}
if [ "$ARCH" = amd64 ] && [ "$ok" = 1 ] && [ "$fb" = 1 ]; then
  identity_realm_wait 2 ssh_guest die_if_qemu_gone
  IR_RC=$?
  if [ "$IR_RC" = 0 ]; then
    sign_in_sequence
    SG_AT=$(( $(date +%s) - START ))
    if [ "$sirep" = 1 ]; then
      if [ -s "$SR_JAR" ]; then
        SR_STAGE="wait"
        store_ready_wait "$SR_TRIES" 2 smoke_fetch die_if_qemu_gone
        SR_RC=$?
      else
        SR_STAGE="signin" SR_REASON="${SG_FAIL:-the password-and-code sign-in wrote no session jar}"
      fi
    fi
    if [ "$SR_STAGE" = wait ]; then
      _f=$(smoke_fetch)
      ID_REPORT=$(identity_report_verdict "${_f%% *}" "${_f#* }")
    fi
  fi
fi
SR_AT=$(( $(date +%s) - START ))
ID_AT=$(( $(date +%s) - START ))

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
  [ "$sirep" = 1 ] || return 0
  grep -aq 'rasputin-store-init: outcome=initialised' "$CONSOLE_LOG" || return 0
  grep -aqE 'rasputin-store-(init|provision): outcome=failed' "$CONSOLE_LOG" && return 0
  # The sign-in and the store read run on amd64 only (identity is masked on
  # arm64), so only there can they call for the journal.
  [ "$ARCH" = amd64 ] || return 1
  [ -z "$SG_FAIL" ] || return 0
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

# The identity database's image facts (geekdojo/geekdojo-brain#972), read in
# one SSH call while the guest still runs, here before the kill, and asserted
# after it with the rest. Only once firstboot has completed: it is what puts
# the seed's key where dropbear reads it. A guest that does not answer leaves
# the file empty, and the assertion says so.
PG_FACTS="$WORK/identity-db.facts"
: > "$PG_FACTS"
if [ "$ok" = 1 ] && [ "$fb" = 1 ]; then
  SSH_CALL_TIMEOUT=120 ssh_guest '
    echo "version=$(postgres --version 2>&1)"
    echo "postgres=$(id -u postgres):$(id -g postgres)"
    echo "keycloak=$(id -u keycloak):$(id -g keycloak)"
    echo "enabled=$(systemctl is-enabled postgresql.service 2>/dev/null)"
    echo "active=$(systemctl show -P ActiveState postgresql.service)"
    echo "failed=$(systemctl list-units --failed --plain --no-legend postgresql.service | grep -c postgresql)"
    echo "running=$(cat /proc/[0-9]*/comm 2>/dev/null | grep -cx postgres)"
    echo "java=$(cat /proc/[0-9]*/comm 2>/dev/null | grep -cx java)"
    echo "pg_cgroups=$(for p in $(pidof postgres); do sed -n "s/^0:://p" /proc/$p/cgroup; done | sort -u | tr "\n" " ")"
  ' > "$PG_FACTS" 2>&1 || echo "identity-db facts: the guest's SSH call returned status $? (asserted below)"
fi

# The identity service's image facts (geekdojo/geekdojo-brain#971), read the
# same way. Facts only: nothing here runs kc.sh. On amd64 the units run it
# under KVM (#974); on arm64 they are masked, and kc.sh under the image's
# shell and --optimized are proven on the bench (TC-971-26, TC-971-27).
KC_FACTS="$WORK/keycloak.facts"
: > "$KC_FACTS"
if [ "$ok" = 1 ] && [ "$fb" = 1 ]; then
  SSH_CALL_TIMEOUT=120 ssh_guest '
    echo "version=$(cat /usr/lib/keycloak/version.txt 2>&1)"
    echo "data=$(readlink /usr/lib/keycloak/data)"
    echo "theme=$(readlink /usr/lib/keycloak/themes/rasputin)"
    echo "sh=$(readlink -f /bin/sh)"
  ' > "$KC_FACTS" 2>&1 || echo "keycloak facts: the guest's SSH call returned status $? (asserted below)"
fi

# The identity units' image facts (geekdojo/geekdojo-brain#973; #974,
# TC-974-23 and TC-974-26), read the same way, on each SKU's smoke. On amd64
# they are read after the realm wait above (F-974-05), so both units are
# enabled by post-build.sh's links and active. On arm64 both are masked on the
# kernel cmdline, so they read LoadState=masked.
ID_FACTS="$WORK/identity-units.facts"
: > "$ID_FACTS"
if [ "$ok" = 1 ] && [ "$fb" = 1 ]; then
  SSH_CALL_TIMEOUT=120 ssh_guest '
    echo "curl=$(curl --version 2>&1 | head -1)"
    echo "protocols=$(curl --version 2>&1 | sed -n "s/^Protocols: //p")"
    echo "api_oom=$(cat /proc/$(systemctl show -P MainPID rasputin-api.service)/oom_score_adj 2>&1)"
    echo "agent_oom=$(cat /proc/$(systemctl show -P MainPID rasputin-agent.service)/oom_score_adj 2>&1)"
    for u in keycloak keycloak-db; do
      echo "${u}_load=$(systemctl show -P LoadState $u.service)"
      echo "${u}_state=$(systemctl show -P ActiveState $u.service)"
      echo "${u}_enabled=$(systemctl is-enabled $u.service 2>/dev/null)"
    done
    echo "failed=$(systemctl list-units --failed --plain --no-legend keycloak.service keycloak-db.service | grep -c keycloak)"
    [ -x /usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh ] && echo hook=executable || echo hook=not-executable
  ' > "$ID_FACTS" 2>&1 || echo "identity units facts: the guest's SSH call returned status $? (asserted below)"
fi

# (d) The identity guest checks (geekdojo/geekdojo-brain#967, #974),
# test/lib/identity-guest-checks.sh with its two libraries, copied over SSH
# stdin into a guest tmpfs directory and run as root with the image's values:
# listen and listen-only (uids 991 and 992 on exactly 127.0.0.1:8543, :8544
# and :5432), kc-tls on both Keycloak ports with the api's client leaf,
# pg-tls with the db-client leaf (so the LoadCredential= key serves TLS on
# the real image), pg-socket and at-rest. Every line must be PASS.
# (e) keycloak.service's memory, recorded per build (F-974-04): memory.peak,
# the running unit's MemoryMax, memory.events max and oom_kill, and
# memory.stat anon.
# (f) The role gate: role.controlplane moved aside and both units restarted,
# each must be skipped (ConditionResult=no, inactive, not failed), and the
# api's report must then hold an identity: id, which shows the api runs in
# keycloak mode. The marker is restored. Last, because it stops both units.
GC_OUT="$WORK/identity-guest-checks.out" MEM_FACTS="$WORK/identity-memory.facts" RG_FACTS="$WORK/identity-role-gate.facts"
GC_RC="" RG_REPORT=""
: > "$GC_OUT"; : > "$MEM_FACTS"; : > "$RG_FACTS"
if [ "$ARCH" = amd64 ] && [ "$IR_RC" = 0 ]; then
  GD=/run/boot-smoke-identity
  if ssh_guest "umask 077 && mkdir -p $GD" </dev/null \
    && ssh_guest "cat >$GD/identity-guest-checks.sh" <"$LIBDIR/identity-guest-checks.sh" \
    && ssh_guest "cat >$GD/listen-sockets.sh" <"$LIBDIR/listen-sockets.sh" \
    && ssh_guest "cat >$GD/secret-scan.sh" <"$LIBDIR/secret-scan.sh"; then
    V=/var/lib/rasputin
    SSH_CALL_TIMEOUT=120 ssh_guest "KC_HTTPS_PORT=8543 KC_MGMT_PORT=8544 DB_PORT=5432 DB_NAME=keycloak DB_USER=keycloak \
      CA=$V/trust/identity-ca.pem CLIENT_LEAF=$V/tls/identity-api-client/leaf \
      DB_CA=$V/trust/identity-ca.pem DB_CLIENT_LEAF=$V/tls/identity-db-client/leaf PSQL=/usr/bin/psql \
      ATREST_CMD='/usr/lib/rasputin/atrest/rasputin-atrest-audit.sh -q' PERSIST=$V DB_DATA=$V/identity-db/data \
      OUT=$GD/out ID_UIDS='991 992' sh $GD/identity-guest-checks.sh checks" </dev/null > "$GC_OUT" 2>&1
    GC_RC=$?
    ssh_guest "rm -rf $GD" </dev/null >/dev/null 2>&1
  else
    echo "identity guest checks: the scripts could not be copied to the guest" > "$GC_OUT"
    GC_RC=copy
  fi
  SSH_CALL_TIMEOUT=120 ssh_guest '
    cg=/sys/fs/cgroup$(systemctl show -P ControlGroup keycloak.service)
    echo "state=$(systemctl show -P ActiveState keycloak.service)"
    echo "peak=$(cat $cg/memory.peak 2>&1)"
    echo "memory_max=$(systemctl show -P MemoryMax keycloak.service)"
    echo "events_max=$(awk "\$1 == \"max\" { print \$2 }" $cg/memory.events 2>&1)"
    echo "oom_kill=$(awk "\$1 == \"oom_kill\" { print \$2 }" $cg/memory.events 2>&1)"
    echo "anon=$(awk "\$1 == \"anon\" { print \$2 }" $cg/memory.stat 2>&1)"
  ' </dev/null > "$MEM_FACTS" 2>&1 || echo "identity memory: the guest's SSH call returned status $? (asserted below)"
  R=/var/lib/rasputin/role.controlplane
  SSH_CALL_TIMEOUT=120 ssh_guest "
    mv $R $R.smoke-aside && echo moved=yes || echo moved=no
    systemctl restart keycloak-db.service keycloak.service
    for u in keycloak keycloak-db; do
      echo \"\${u}=\$(systemctl show -P ConditionResult \$u.service) \$(systemctl show -P ActiveState \$u.service)\"
    done
    echo \"failed=\$(systemctl list-units --failed --plain --no-legend keycloak.service keycloak-db.service | grep -c keycloak)\"
    true
  " </dev/null > "$RG_FACTS" 2>&1 || echo "identity role gate: the guest's SSH call returned status $? (asserted below)"
  if [ "$SR_STAGE" = wait ]; then
    _f=$(smoke_fetch)
    RG_REPORT=$(identity_report_verdict "${_f%% *}" "${_f#* }")
  fi
  ssh_guest "mv $R.smoke-aside $R && echo restored=yes || echo restored=no" </dev/null >> "$RG_FACTS" 2>&1
fi

kill "$QPID" 2>/dev/null || true
echo "----- last 60 lines of console -----"; tail -60 "$CONSOLE_LOG" || true
echo "----- $ARCH smoke timings (seconds from qemu start) -----"
echo "https /healthz on its first read after :80 answered: HTTP ${HS_FIRST:-not asked}"
SG_SHOW=${SG_AT:+${SG_AT}s}
echo "multi-user=${MU_AT}s firstboot=${FB_AT}s api+ui+dns=${API_AT}s atrest-verdict=${ATREST_AT}s tailscale-report=${TS_AT}s kernel-match=${KM_AT}s store-init=${SI_AT}s signin=${SG_SHOW:-not-run} store-ready=${SR_AT}s identity-ready=${ID_AT}s total(incl. 70s soak)=${TOTAL}s"

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

# The passkey RP ID's derivation from the cluster id is asserted with the
# first-run sign-in below (amd64): the home door's registration and sign-in
# pages must both name sso-<cluster>.local (geekdojo/geekdojo-brain#993).

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

# The identity database (geekdojo/geekdojo-brain#972), from the facts read over
# SSH before the kill. The image carries our own PostgreSQL at the version its
# package pins, whose major is 18 (a literal here: a different major is a
# planned upgrade, never a bump), the two static users at their fixed ids, and
# Buildroot's own postgresql.service masked after the real preset-all, so
# nothing starts it.
PG_EXPECT="$(sed -n 's/^RASPUTIN_POSTGRESQL_VERSION = //p' "$(dirname "$0")/../package/rasputin-postgresql/rasputin-postgresql.mk" | tr -d '[:space:]')"
[ -n "$PG_EXPECT" ] \
  || { echo "::error::could not read RASPUTIN_POSTGRESQL_VERSION from package/rasputin-postgresql/rasputin-postgresql.mk — this assertion has nothing to compare against"; exit 1; }
[ "${PG_EXPECT%%.*}" = 18 ] \
  || { echo "::error::package/rasputin-postgresql pins PostgreSQL $PG_EXPECT, whose major is not 18 — a major change is the planned upgrade item, never a bump"; exit 1; }
pg_fact() { sed -n "s/^$1=//p" "$PG_FACTS" | tr -d '\r' | head -1; }
[ -s "$PG_FACTS" ] \
  || { echo "::error::the guest did not answer the identity database's SSH query before the kill, so nothing checked the PostgreSQL binary, its users or its masked unit"; exit 1; }
echo "identity database facts:"; sed 's/^/  /' "$PG_FACTS"
[ "$(pg_fact version)" = "postgres (PostgreSQL) $PG_EXPECT" ] \
  || { echo "::error::postgres --version on the image is '$(pg_fact version)', expected 'postgres (PostgreSQL) $PG_EXPECT' from package/rasputin-postgresql"; exit 1; }
[ "$(pg_fact postgres)" = "992:992" ] \
  || { echo "::error::the postgres user is uid:gid '$(pg_fact postgres)' on the image, expected 992:992 from package/rasputin-identity-db"; exit 1; }
[ "$(pg_fact keycloak)" = "991:991" ] \
  || { echo "::error::the keycloak user is uid:gid '$(pg_fact keycloak)' on the image, expected 991:991 from package/rasputin-identity-db"; exit 1; }
[ "$(pg_fact enabled)" = masked ] \
  || { echo "::error::systemctl is-enabled postgresql.service says '$(pg_fact enabled)', expected masked — the /dev/null symlink in the rootfs overlay is gone, or preset-all overrode it, and Buildroot's own unit would start a database on every node"; exit 1; }
[ "$(pg_fact active)" = inactive ] \
  || { echo "::error::postgresql.service is '$(pg_fact active)' on the image, expected inactive: something started Buildroot's masked unit"; exit 1; }
[ "$(pg_fact failed)" = 0 ] \
  || { echo "::error::postgresql.service is listed by systemctl --failed on the image"; exit 1; }
if [ "$ARCH" = amd64 ]; then
  # Every postgres process is the identity database's (#974): none from
  # Buildroot's masked unit or anything else.
  [ "$(pg_fact running)" -gt 0 ] 2>/dev/null \
    || { echo "::error::no process named postgres runs on the amd64 image, where keycloak-db.service must be running the identity database"; exit 1; }
  [ "$(pg_fact pg_cgroups)" = "/system.slice/keycloak-db.service " ] \
    || { echo "::error::the postgres processes on the image are in the cgroups '$(pg_fact pg_cgroups)', expected only /system.slice/keycloak-db.service"; exit 1; }
  echo "PostgreSQL $PG_EXPECT on the image, postgres 992:992, keycloak 991:991, postgresql.service masked and inactive, $(pg_fact running) postgres process(es), all in keycloak-db.service"
else
  # arm64: both identity units are masked on the cmdline (TC-974-26).
  [ "$(pg_fact running)" = 0 ] \
    || { echo "::error::$(pg_fact running) process(es) named postgres are running on the arm64 image, where the identity database is masked"; exit 1; }
  [ "$(pg_fact java)" = 0 ] \
    || { echo "::error::$(pg_fact java) process(es) named java are running on the arm64 image, where the identity service is masked"; exit 1; }
  echo "PostgreSQL $PG_EXPECT on the image, postgres 992:992, keycloak 991:991, postgresql.service masked, no postgres or java running (identity masked on arm64)"
fi

# The identity service (geekdojo/geekdojo-brain#971), from the facts read over
# SSH before the kill: the Keycloak the package pins, its two links, and the
# busybox /bin/sh that kc.sh runs under on the node.
KC_EXPECT="$(sed -n 's/^KEYCLOAK_VERSION = //p' "$(dirname "$0")/../package/keycloak/keycloak.mk" | tr -d '[:space:]')"
[ -n "$KC_EXPECT" ] \
  || { echo "::error::could not read KEYCLOAK_VERSION from package/keycloak/keycloak.mk — this assertion has nothing to compare against"; exit 1; }
kc_fact() { sed -n "s/^$1=//p" "$KC_FACTS" | tr -d '\r' | head -1; }
[ -s "$KC_FACTS" ] \
  || { echo "::error::the guest did not answer the identity service's SSH query before the kill, so nothing checked the Keycloak install"; exit 1; }
echo "identity service facts:"; sed 's/^/  /' "$KC_FACTS"
[ "$(kc_fact version)" = "Keycloak - Version $KC_EXPECT" ] \
  || { echo "::error::/usr/lib/keycloak/version.txt on the image says '$(kc_fact version)', expected 'Keycloak - Version $KC_EXPECT' from package/keycloak"; exit 1; }
[ "$(kc_fact data)" = /var/lib/rasputin/keycloak/data ] \
  || { echo "::error::/usr/lib/keycloak/data on the image links to '$(kc_fact data)', expected /var/lib/rasputin/keycloak/data"; exit 1; }
[ "$(kc_fact theme)" = /usr/share/rasputin/identity/theme ] \
  || { echo "::error::/usr/lib/keycloak/themes/rasputin on the image links to '$(kc_fact theme)', expected /usr/share/rasputin/identity/theme"; exit 1; }
case "$(kc_fact sh)" in
  */busybox) ;;
  *) echo "::error::/bin/sh on the image resolves to '$(kc_fact sh)', expected busybox, the shell the bench proves kc.sh under"; exit 1 ;;
esac
echo "Keycloak $KC_EXPECT on the image, data and themes/rasputin linked, /bin/sh is busybox (facts only; kc.sh is proven on the bench)"

# The identity units (geekdojo/geekdojo-brain#973, TC-973-29), from the facts
# read over SSH before the kill, on each SKU: the start wait's curl with
# OpenSSL and HTTPS, the api and the agent at -950 in the OOM order, both
# identity units loaded and never failed, skipped by their conditions once the
# api has minted the leaves (never started: see the facts above), and the hook
# executable. The at-rest verdict
# asserted above covers the identity rows.
id_fact() { sed -n "s/^$1=//p" "$ID_FACTS" | tr -d '\r' | head -1; }
[ -s "$ID_FACTS" ] \
  || { echo "::error::the guest did not answer the identity units' SSH query before the kill, so nothing checked curl, the OOM order or the identity units"; exit 1; }
echo "identity units facts:"; sed 's/^/  /' "$ID_FACTS"
case "$(id_fact curl)" in
  *OpenSSL/*) ;;
  *) echo "::error::curl --version on the image says '$(id_fact curl)', expected a libcurl built with OpenSSL for the start wait"; exit 1 ;;
esac
case " $(id_fact protocols) " in
  *" https "*) ;;
  *) echo "::error::curl on the image lists the protocols '$(id_fact protocols)', which do not include https, so the start wait cannot ask /health/started"; exit 1 ;;
esac
[ "$(id_fact api_oom)" = -950 ] \
  || { echo "::error::rasputin-api's oom_score_adj is '$(id_fact api_oom)', expected -950 (store -999, api and agent -950, identity -900)"; exit 1; }
[ "$(id_fact agent_oom)" = -950 ] \
  || { echo "::error::rasputin-agent's oom_score_adj is '$(id_fact agent_oom)', expected -950 (store -999, api and agent -950, identity -900)"; exit 1; }
[ "$(id_fact hook)" = executable ] \
  || { echo "::error::/usr/lib/rasputin/identity/rasputin-keycloak-hooks.sh is not executable on the image"; exit 1; }
[ "$(id_fact failed)" = 0 ] \
  || { echo "::error::an identity unit is listed by systemctl --failed on the image"; exit 1; }
if [ "$ARCH" = amd64 ]; then
  # (a) The realm wait, before the facts (TC-974-20).
  [ "$IR_RC" = 0 ] \
    || { echo "::error::realm rasputin never answered 200 on its discovery document over mutual TLS on the amd64 control plane; the realm wait ended after ${IR_SECONDS:-?} seconds on: ${IR_LAST:-the wait never ran, because the boot or firstboot did not complete}"; exit 1; }
  echo "realm rasputin answered 200 on its discovery document after $IR_SECONDS seconds"
  # The first-run sign-in through the console (geekdojo/geekdojo-brain#993,
  # issue TC-01 to TC-03). Each failed step printed its own ::error:: line
  # before the kill, naming the fact; this is the verdict.
  [ -z "$SG_FAIL" ] \
    || { echo "::error::the first-run sign-in through the console stopped after ${SG_AT:-?}s: $SG_FAIL (the step's own error above names the fact)"; exit 1; }
  # Credentials bind to the RP ID, so a wrong derivation does not error: it
  # makes a cluster whose passkeys silently cannot be used.
  [ "$SG_RPID" = "sso-${CONSOLE_HOST}" ] && [ "$SG_RPID2" = "sso-${CONSOLE_HOST}" ] \
    || { echo "::error::the home door's passkey RP ID is '${SG_RPID:-none}' at enrolment and '${SG_RPID2:-none}' at sign-in, expected 'sso-${CONSOLE_HOST}': it did not derive from RASPUTIN_CLUSTER_ID"; exit 1; }
  case ",$SG_ROLES," in
    *,admin,*) ;;
    *) echo "::error::the password-and-code sign-in after the grant holds the console roles '${SG_ROLES:-none}', with no admin: the first account did not become administrator"; exit 1 ;;
  esac
  [ "$APP_CODE" = 200 ] && [ "$APP_ISSUER" = "https://${APP_HOST}/realms/rasputin" ] \
    || { echo "::error::the app door's discovery document at https://${APP_HOST} answered HTTP ${APP_CODE:-000} with the issuer '${APP_ISSUER:-none}', expected 200 and https://${APP_HOST}/realms/rasputin over a certificate the cluster's CA verifies"; exit 1; }
  echo "first-run sign-in in ${SG_AT}s: the account was made with its recovery codes, added an authenticator app and a passkey through the launcher (RP ID $SG_RPID), became administrator only after the grant ended its sessions (roles $SG_ROLES), signed out, and signed in by password and code, by passkey (RP ID $SG_RPID2) and by recovery code; its password alone was refused, and the home door refused$SG_NEG"
  echo "the app door answered its discovery document by its own name with the issuer $APP_ISSUER"
  # (b) The api's identity report (TC-974-21).
  [ "$ID_REPORT" = ready ] \
    || { echo "::error::the api does not report the identity service ready after realm rasputin answered: GET /api/alerts said '${ID_REPORT:-nothing, because the store check had no session to read it with}'"; exit 1; }
  echo "the api reports the identity service ready: GET /api/alerts holds no identity: alert"
  # (c) Both units enabled by post-build.sh's links, and active (TC-974-23).
  for u in keycloak keycloak-db; do
    [ "$(id_fact "${u}_enabled")" = enabled ] \
      || { echo "::error::systemctl is-enabled $u.service says '$(id_fact "${u}_enabled")' on the amd64 image, expected enabled by post-build.sh's link"; exit 1; }
    [ "$(id_fact "${u}_state")" = active ] \
      || { echo "::error::$u.service is '$(id_fact "${u}_state")' on the amd64 image after the realm answered, expected active"; exit 1; }
  done
  echo "identity units enabled and active, none failed; curl with OpenSSL and https, api and agent at -950, hook executable"
  # (d) The guest checks (TC-974-22).
  echo "identity guest checks:"; sed 's/^/  /' "$GC_OUT"
  [ "$GC_RC" = 0 ] && [ -s "$GC_OUT" ] && ! grep -qv '^PASS ' "$GC_OUT" \
    || { echo "::error::the identity guest checks did not all pass on the amd64 image (exit ${GC_RC:-not run}): $(grep -v '^PASS ' "$GC_OUT" | head -1)"; exit 1; }
  echo "identity guest checks: every line PASS"
  # (e) Memory, recorded; only an OOM kill or an inactive unit fails (TC-974-24).
  mem_fact() { sed -n "s/^$1=//p" "$MEM_FACTS" | tr -d '\r' | head -1; }
  echo "keycloak.service memory: memory.peak=$(mem_fact peak) MemoryMax=$(mem_fact memory_max) memory.events max=$(mem_fact events_max) oom_kill=$(mem_fact oom_kill) memory.stat anon=$(mem_fact anon) state=$(mem_fact state)"
  [ "$(mem_fact oom_kill)" = 0 ] && [ "$(mem_fact state)" = active ] \
    || { echo "::error::keycloak.service was OOM-killed or is not active: oom_kill=$(mem_fact oom_kill) state=$(mem_fact state) memory.peak=$(mem_fact peak) MemoryMax=$(mem_fact memory_max) memory.events max=$(mem_fact events_max) anon=$(mem_fact anon)"; exit 1; }
  # (f) The role gate (TC-974-25).
  echo "identity role gate:"; sed 's/^/  /' "$RG_FACTS"
  rg_fact() { sed -n "s/^$1=//p" "$RG_FACTS" | tr -d '\r' | head -1; }
  for u in keycloak keycloak-db; do
    [ "$(rg_fact "$u")" = "no inactive" ] \
      || { echo "::error::with role.controlplane moved aside, $u.service reads '$(rg_fact "$u")', expected ConditionResult=no and inactive"; exit 1; }
  done
  [ "$(rg_fact failed)" = 0 ] \
    || { echo "::error::with role.controlplane moved aside, an identity unit is listed by systemctl --failed"; exit 1; }
  case "$RG_REPORT" in
    "not-ready: "*identity:*) ;;
    *) echo "::error::with both identity units skipped, GET /api/alerts holds no identity: alert ('${RG_REPORT:-not read}'), so the api is not running in keycloak mode"; exit 1 ;;
  esac
  [ "$(rg_fact restored)" = yes ] \
    || { echo "::error::role.controlplane could not be restored after the role gate"; exit 1; }
  echo "role gate: both identity units skipped without the marker, the api reported '${RG_REPORT#not-ready: }', marker restored"
else
  # arm64 (TC-974-26): both identity units masked on the cmdline.
  for u in keycloak keycloak-db; do
    [ "$(id_fact "${u}_load")" = masked ] \
      || { echo "::error::$u.service is LoadState '$(id_fact "${u}_load")' on the arm64 image, expected masked by the cmdline's systemd.mask"; exit 1; }
  done
  echo "identity units masked on arm64 (identity never runs emulated); curl with OpenSSL and https, api and agent at -950, hook executable; no sign-in runs here (arm64 sign-in is the bench walk, geekdojo/geekdojo-brain#998)"
fi

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
# check never ran, the sign-in failed, or the store never read ready. Read on
# amd64 only: the report needs a session, and the sign-in that makes one runs
# where identity does (#993). arm64's store proves itself above and below by
# outcome=initialised and outcome=applied changed=3.
rm -f "$SR_JAR"
if [ "$ARCH" = amd64 ]; then
  store_ready_report "$SR_STAGE" "$SR_REASON" "$SR_RC" "$SR_LAST" "$SR_AT" || exit 1
else
  echo "the api's store report is read on amd64 only, where the sign-in runs (identity is masked on arm64)"
fi
# The store's provisioner (geekdojo/geekdojo-brain#805, TC-805-35). After the
# store's first start the provisioner runs once. This release's provision.tsv
# lists the app-key engine, its policy and its role (#1084, TC-1084-36), added
# on a fresh store through the author identity init.json now makes, so its
# first line is outcome=applied changed=3. A failed line fails the image; so
# does silence: then nothing provisioned, or nothing recorded that it did. So
# does unchanged: on a fresh store that means the author role is missing and
# app keys are unavailable.
PV_LINE="$(grep -ao 'rasputin-store-provision: outcome=.*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
if grep -aq 'rasputin-store-provision: outcome=failed' "$CONSOLE_LOG"; then
  echo "::error::the secrets store's provisioner FAILED on a fresh control plane: $(grep -ao 'rasputin-store-provision: outcome=failed.*' "$CONSOLE_LOG" | tr -d '\r' | head -1)"
  exit 1
fi
# Nor may systemd have failed a provisioner job with result 'dependency'
# (ledger F-805-28). On a fresh flash the store is condition-skipped until the
# api mints its leaves; a provisioner job queued beside that skipped start
# fails its Requisite= and prints this on every first boot, even though a
# later run of the store still provisions and reports its outcome.
PV_DEP="Dependency failed for .*Secrets store provisioner|rasputin-store-provision\\.service: Job .* failed with result 'dependency'"
if grep -aqE "$PV_DEP" "$CONSOLE_LOG"; then
  echo "::error::systemd failed a secrets store provisioner job with result 'dependency' on a fresh control plane (F-805-28): something queued rasputin-store-provision.service beside a store start that never reached READY — openbao.service must start it only from its last ExecStartPost=: $(grep -aoE "$PV_DEP" "$CONSOLE_LOG" | tr -d '\r' | head -1)"
  exit 1
fi
case "$PV_LINE" in
  "rasputin-store-provision: outcome=applied changed=3 "*) echo "secrets store provisioner ran after the store's first start: ${PV_LINE%% reason=*}" ;;
  "") echo "::error::no 'rasputin-store-provision: outcome=' line reached the serial console in ${SI_AT}s — the store's provisioner never ran after its first start, or openbao.service lost the ExecStartPost= that starts rasputin-store-provision.service."; exit 1 ;;
  *) echo "::error::the secrets store's provisioner did not report outcome=applied changed=3 (the app-key engine, policy and role, geekdojo/geekdojo-brain#1084) on a fresh control plane: $PV_LINE"; exit 1 ;;
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
# carries the first failing path and what is wrong with it (its actual mode, or
# its actual uid or gid for an owner or group failure), so a red build says
# WHICH file regressed rather than only that an assertion failed.
#
# Read back AFTER the kill, so qemu is no longer appending to the file while
# this greps it (the arrival was polled above, before the kill).
ATREST_LINES="$(grep -o 'rasputin-atrest: .*' "$CONSOLE_LOG" | tr -d '\r')"
if [ "$atrest" != 1 ] || [ -z "$ATREST_LINES" ]; then
  echo "::error::no 'rasputin-atrest:' verdict reached the serial console in ${ATREST_AT}s — the at-rest mode audit never reported, so NOTHING checked the modes on the persistent partition on this boot. Treated exactly like a FAIL: check that rasputin-atrest-audit.service is still in the overlay, still WantedBy=multi-user.target, not masked, and that its ordering (After=rasputin-api.service rasputin-agent.service) did not leave it behind a unit that never started; check too that the verdict still goes to /dev/kmsg, since journald's output does not reach this console."
  echo "----- any atrest-related console lines (if one appears here, the verdict's own wording changed and this assertion has drifted from rasputin-atrest-audit.sh) -----"
  atrest_ctx="$(grep -nE "atrest" "$CONSOLE_LOG" | tail -20)"
  echo "${atrest_ctx:-(not one line mentions the audit — the unit did not run at all)}"
  exit 1
fi
if printf '%s\n' "$ATREST_LINES" | grep -q "rasputin-atrest: FAIL"; then
  echo "::error::the at-rest mode audit FAILED on the booted machine — a path on the persistent partition is not the mode, owner or group /usr/lib/rasputin/atrest/inventory declares for it, or a swept tree holds a group/world-accessible file. The verdict below carries the count and the FIRST offending path with what is wrong with it: its actual mode, or its actual uid or gid for an owner or group failure; the remaining findings are printed on the audit's stdout, which systemd captures into the guest's journal and which therefore does NOT reach this console — reproduce them with test/atrest-modes-test.sh or on a node. Either the path regressed or the inventory is out of date — do not widen the inventory to match a widened file."
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
#
# THE ROTATION PRECONDITION, AND WHERE IT COMES FROM. Assertion (f) needs
# journald to rotate on the clock-floor jump, so boot 2's first entry has to be
# dated before boot 1's last. Until now the leg got that from shutdown timing.
# Boot 2 restores the floor that clock-save's ExecStop writes in boot 1's
# shutdown, and boot 1's journal ran on past that save only because the reboot
# stalled about 90s on rasputin-atrest-audit.service: its INT/TERM trap removed
# the work directory and then let the audit carry on, so systemd waited out the
# stop timeout and SIGKILLed it. A reboot that missed the audit left a margin
# of about -0.6s, no rotation, and (f) failed. That stall was a product defect,
# not a test fixture, and the audit now exits on TERM.
#
# So the leg forges the floor instead, and the precondition no longer depends
# on shutdown timing. Boot 1 runs with -no-reboot, so growpart's reboot ends
# QEMU and boot 2 does not start. On the host, debugfs then sets
# /var/lib/rasputin/clock on the image's persistent filesystem to the value
# clock-save's ExecStart wrote early in boot 1, read from boot 1's console. Boot
# 1 logged entries after that save, so boot 2's floor is behind boot 1's last
# entry by construction. Boot 2 then runs as an ordinary QEMU boot of the same
# image, and (a)-(i) read it as before. The leg prints the forged value and the
# console line it came from.
#
# The leg waits on facts: the main QEMU having exited (it holds SSH_PORT), then
# boot 1's QEMU exiting on growpart's reboot, with a grown: line in
# growpart.log, then `already-full` in growpart.log, which only the post-grow
# boot writes, then that boot's seal-key outcome line, which is not ordered
# against growpart. QEMU's BOOT_BUDGET bounds each of the two processes.

# The main QEMU was killed above; its exit frees SSH_PORT for the leg's forward.
wait "$QPID" 2>/dev/null
QPID=""
truncate -s +8G "$GROW_IMG" \
  || { echo "::error::could not grow $GROW_IMG by 8G for the growpart leg"; exit 1; }
if [ "$ARCH" = amd64 ]; then
  cp "$OVMF_VARS" "$WORK/grow-vars.fd" \
    || { echo "::error::could not copy the OVMF vars for the growpart leg"; exit 1; }
  VARS_FD="$WORK/grow-vars.fd"
else
  # The shipped cmdline with only `virt`'s console added: no
  # systemd.log_target=kmsg. The leg polls over SSH, not the console, and with
  # PID 1 logging to kmsg its unit messages reach the journal as kernel lines
  # without UNIT= or MESSAGE_ID=, which assertion (i) reads. A Pi logs them to
  # the journal, as this boot now does.
  QEMU_APPEND="$SHIPPED_CMDLINE console=ttyAMA0,115200 $ARM64_ID_MASKS"
  echo "growpart leg kernel cmdline: $QEMU_APPEND"
fi
# die_if_qemu_gone reads QPID and CONSOLE_LOG: from here on they are the leg's.
# The main boot's console stays where the workflow uploads it from.
GROW_FWD="restrict=on,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"
CONSOLE_LOG="$WORK/grow1-console.log"
: > "$CONSOLE_LOG"
# QEMU_NO_KVMCLOCK=1: on amd64 under KVM the guest's wall clock otherwise comes
# from the host through kvmclock and -rtc base= has no effect, so the floor
# would never be the clock source (geekdojo/geekdojo-brain#974). Both of the
# leg's boots; the main boot keeps KVM's default.
QEMU_NO_KVMCLOCK=1 qemu_exec "$ARCH" "$GROW_IMG" "$BOOT_BUDGET" "$CONSOLE_LOG" "$GROW_FWD" \
  -rtc base=2000-01-01T00:00:00 -no-reboot &
QPID=$!
echo "growpart leg: boot 1 of $GROW_IMG (+8G) with the RTC at 2000-01-01, no route out, and -no-reboot"
# Boot 1 ends when its QEMU exits: with -no-reboot, growpart's reboot does that
# with status 0. 124 is `timeout` reaching BOOT_BUDGET.
wait "$QPID"; GROW_B1_ST=$?
QPID=""
case "$GROW_B1_ST" in
  0) ;;
  124) echo "::error::growpart leg ($ARCH): boot 1 did not reboot before qemu's budget expired"
       echo "----- boot 1's console (whole file) -----"; cat "$CONSOLE_LOG" || true
       exit 1 ;;
  *) echo "::error::growpart leg ($ARCH): boot 1's qemu exited with status $GROW_B1_ST, not on a guest reboot"
     echo "----- boot 1's console (whole file) -----"; cat "$CONSOLE_LOG" || true
     exit 1 ;;
esac

# The persistent filesystem, found by the label rasputin-init mounts it by.
PERSIST_OFF=""
for _off in $(sfdisk -J "$GROW_IMG" | jq -r '.partitiontable.partitions[] | .start * 512'); do
  if [ "$(blkid -p -O "$_off" -s LABEL -o value "$GROW_IMG" 2>/dev/null)" = persistent ]; then
    PERSIST_OFF=$_off; break
  fi
done
if [ -z "$PERSIST_OFF" ]; then
  echo "::error::growpart leg ($ARCH): no partition of $GROW_IMG holds a filesystem labelled persistent after boot 1"
  sfdisk -J "$GROW_IMG"
  exit 1
fi
PERSIST_FS="$GROW_IMG?offset=$PERSIST_OFF"
# debugfs prints its banner on stderr and `cat` writes the file to stdout.
pfs_cat() { debugfs -R "cat $1" "$PERSIST_FS" 2>/dev/null; }
GROW_B1_LOG=$(pfs_cat /growpart.log)
if ! printf '%s\n' "$GROW_B1_LOG" | awk '$2 == "grown:" { g = 1 } END { exit !g }'; then
  echo "::error::growpart leg ($ARCH): boot 1 ended without a grown: line in growpart.log, so its exit was not growpart's reboot"
  echo "----- growpart.log after boot 1 -----"; printf '%s\n' "${GROW_B1_LOG:-(empty or unreadable)}"
  echo "----- boot 1's console (whole file) -----"; cat "$CONSOLE_LOG" || true
  exit 1
fi

# The forged floor: clock-save's first save in boot 1, its ExecStart.
FLOOR_SAVE=$(tr -d '\r' < "$CONSOLE_LOG" | grep -m 1 -E 'rasputin-clock-save: saved clock [0-9]{10} ')
FLOOR_FORGED=$(printf '%s\n' "$FLOOR_SAVE" | sed -n 's/.*rasputin-clock-save: saved clock \([0-9]\{10\}\) .*/\1/p')
if [ -z "$FLOOR_FORGED" ]; then
  echo "::error::growpart leg ($ARCH): boot 1's console holds no 'rasputin-clock-save: saved clock' line, so there is no floor from boot 1 to forge"
  echo "----- boot 1's console (whole file) -----"; cat "$CONSOLE_LOG" || true
  exit 1
fi
FLOOR_LEFT=$(pfs_cat /clock)
if ! { printf '%s\n' "$FLOOR_FORGED" > "$WORK/forged-clock" && chmod 0644 "$WORK/forged-clock"; }; then
  echo "::error::could not write $WORK/forged-clock"; exit 1
fi
# debugfs exits 0 when a command fails, so the write is judged by reading back.
printf 'rm /clock\nwrite %s /clock\n' "$WORK/forged-clock" | debugfs -w -f - "$PERSIST_FS" >/dev/null 2>&1
FLOOR_READ=$(pfs_cat /clock)
if [ "$FLOOR_READ" != "$FLOOR_FORGED" ]; then
  echo "::error::growpart leg ($ARCH): debugfs did not set /var/lib/rasputin/clock to $FLOOR_FORGED: it reads '${FLOOR_READ}'"
  exit 1
fi
echo "growpart leg ($ARCH) clock: forged floor $FLOOR_FORGED into /var/lib/rasputin/clock (boot 1 left ${FLOOR_LEFT:-nothing}), from boot 1's first save: $FLOOR_SAVE"

CONSOLE_LOG="$WORK/grow2-console.log"
: > "$CONSOLE_LOG"
QEMU_NO_KVMCLOCK=1 qemu_exec "$ARCH" "$GROW_IMG" "$BOOT_BUDGET" "$CONSOLE_LOG" "$GROW_FWD" \
  -rtc base=2000-01-01T00:00:00 &
QPID=$!
echo "growpart leg: boot 2 of $GROW_IMG on the forged floor"

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
  echo "----- boot 1 from growpart's reboot to its last entry (journalctl -o short-unix) -----"; leg_tail
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
# Where the margin comes from, always recorded. Boot 2's clock starts at the
# floor the leg forged from clock-save's ExecStart in boot 1, so the margin is
# boot 1's run after that save less boot 2's lead to its first entry. The
# lines below name the saves, the floor boot 2 restored, and every gap of a
# second or more in boot 1's shutdown, with the entry that ended it.
B1_JOURNAL="$WORK/grow-boot1.journal"
ssh_guest 'journalctl -b -1 -o short-unix --no-pager' > "$B1_JOURNAL" 2>/dev/null || : > "$B1_JOURNAL"
# journald files a /dev/kmsg line under the identifier its prefix names, so
# rasputin-init's floor line is read with -t, not grepped for its prefix.
echo "growpart leg ($ARCH) clock: boot 1 clock-save: $(grep -F ' rasputin-clock-save.sh[' "$B1_JOURNAL" | tr '\n' '|')"
echo "growpart leg ($ARCH) clock: boot 2 floor: $(ssh_guest 'journalctl -b 0 -t rasputin-init -o short-unix --no-pager' 2>/dev/null | tr -d '\r' | grep -iF clock | tr '\n' '|')"
leg_tail() { awk '/table extended; rebooting/ { p = 1 } p' "$B1_JOURNAL"; }
leg_tail | awk -v arch="$ARCH" '{ t = $1 + 0; if (n++ && t - prev >= 1) printf "growpart leg (%s) clock: boot 1 shutdown gap %.3fs before: %s\n", arch, t - prev, $0; prev = t }'
leg_tail | grep -E "timed out|Killing" | sed "s/^/growpart leg ($ARCH) clock: boot 1 shutdown stall: /"

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
  || leg_fail "journalctl -b 0 has no 'Realtime clock jumped backwards' line: the clock-floor rotation was not reproduced (boot 1 last __REALTIME_TIMESTAMP=${B1_LAST:-none}, boot 2 first __REALTIME_TIMESTAMP=${B2_FIRST:-none}, margin ${MARGIN}us, forged floor ${FLOOR_FORGED}), so this run did not exercise the deletion path"
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
LEG_MISSING=""
case "$API_STARTED" in
  ''|*[!0-9]*) LEG_MISSING="the UNIT=rasputin-api.service \"Started\" entry (MESSAGE_ID 39f53479d3a045ac8e11786248231fbf)" ;;
esac
case "$GROW_STARTING" in
  ''|*[!0-9]*) LEG_MISSING="${LEG_MISSING:+$LEG_MISSING and }the UNIT=rasputin-growpart.service \"Starting\" entry (MESSAGE_ID 7d4958e842da4a758f6c1cdc7b36dcc5)" ;;
esac
[ -z "$LEG_MISSING" ] \
  || leg_fail "journalctl -b -1 has no $LEG_MISSING, so whether the grow waited for the api's READY=1 in the provisioning boot cannot be read"
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
