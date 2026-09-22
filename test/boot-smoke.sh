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

# Host-side forwards into the guest. The same numbers serve both arches: the two
# smoke jobs run on separate runners, so they never collide.
HTTP_PORT=18080
HTTPS_PORT=18443
DNS_PORT=15353

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
BOOT_BUDGET=900 ; MU_TRIES=120 ; FB_TRIES=60 ; API_TRIES=48 ; ATREST_TRIES=60
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
printf 'RASPUTIN_NODE_ROLE=controlplane\nRASPUTIN_NODE_ID=smoke-cp\nRASPUTIN_CLUSTER_ID=%s\nRASPUTIN_NATS_URL=\nRASPUTIN_CP_JOIN_TOKEN=\n' \
  "$CLUSTER_ID" > "$WORK/seed-cp.env"

# The seed ships on its own auto-mounting FAT partition on BOTH SKUs (the
# running image finds it by FS label RASPUTIN-OS, not by number). We find its
# byte offset from the partition table so the recipe survives a layout change,
# and so ONE selector serves both tables:
#
#   n100 — GPT: the seed is Microsoft basic data (EBD0A0A2-…), deliberately NOT
#          the EFI System partition, which Windows and macOS hide from the user.
#   rpi  — MBR: `sfdisk -J` reports the selector FAT as type "c" + bootable. It
#          is the ONLY bootable entry in that table (boot-a/boot-b are type "c"
#          as well but carry no boot flag), so the pair is unambiguous. MBR is
#          forced on the Pi because the firmware's autoboot.txt boot_partition
#          switch is broken on GPT (rpi-eeprom#654).
#
# mtools keeps the recipe identical to the macOS bench one.
SEED_OFF=$(sfdisk -J "$IMG" | jq -r '
  .partitiontable.partitions[]
  | select(((.type | ascii_upcase) == "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7")
        or ((.type | ascii_downcase) == "c" and (.bootable == true)))
  | .start * 512' | head -1)
if [ -z "$SEED_OFF" ]; then
  echo "::error::could not locate the seed partition in $IMG — the table below matches neither the GPT (Microsoft-basic-data) nor the MBR (bootable type 0x0c) seed"
  sfdisk -J "$IMG"
  exit 1
fi
echo "seed partition at byte offset $SEED_OFF"
MTOOLS_SKIP_CHECK=1 mcopy -o -i "$IMG"@@"$SEED_OFF" "$WORK/seed-cp.env" ::rasputin-seed.env \
  || { echo "::error::could not write the seed onto the FAT at offset $SEED_OFF"; exit 1; }

# ------------------------------------------------------- arch preparation -----
prepare_amd64() {
  # Ubuntu's ovmf package renamed the firmware files (the un-suffixed
  # OVMF_CODE.fd / OVMF_VARS.fd are gone on 24.04+; the 4M variants are the
  # modern names, and the secboot ones require signed bootloaders which our
  # GRUB isn't). Pick whichever non-secboot variant is installed.
  OVMF_CODE=""; OVMF_VARS=""
  for f in /usr/share/OVMF/OVMF_CODE*.fd; do
    case "$f" in *secboot*) continue ;; esac
    [ -f "$f" ] || continue; OVMF_CODE="$f"; break
  done
  for f in /usr/share/OVMF/OVMF_VARS*.fd; do
    case "$f" in *secboot*) continue ;; esac
    [ -f "$f" ] || continue; OVMF_VARS="$f"; break
  done
  if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS" ]; then
    echo "::error::OVMF firmware not found"; ls -la /usr/share/OVMF/ || true; exit 1
  fi
  echo "using OVMF code=$OVMF_CODE vars=$OVMF_VARS"
  cp "$OVMF_VARS" "$WORK/vars.fd"
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
  case "$ARCH" in
  amd64)
    # -cpu max: advertise every ISA extension QEMU's TCG knows. The image is
    # built with BR2_x86_corei7 (Nehalem baseline → SSE4.2); the default qemu64
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
    exec timeout "$BOOT_BUDGET" qemu-system-x86_64 \
      -machine q35 -m 2048 -smp 2 -cpu max -nographic \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$WORK/vars.fd" \
      -drive file="$IMG",format=raw,if=virtio \
      -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${HTTPS_PORT}-:443,hostfwd=udp:127.0.0.1:${DNS_PORT}-:53,hostfwd=tcp:127.0.0.1:${DNS_PORT}-:53" \
      -serial mon:stdio > "$CONSOLE_LOG" 2>&1
    ;;
  arm64)
    # gic-version is pinned rather than left to QEMU's per-version default, so a
    # runner-image bump cannot silently change the interrupt controller under
    # us; the kernel carries both ARM_GIC and ARM_GIC_V3.
    #
    # romfile= (empty) disables the NIC's PXE option ROM. Ubuntu's
    # qemu-system-x86 depends on ipxe-qemu and qemu-system-arm does NOT, so on
    # the arm64 runner virtio-net-pci dies at startup with `failed to find
    # romfile "efi-virtio.rom"` — QEMU never runs at all. We boot with -kernel
    # and never PXE, so the ROM is dead weight; dropping it beats adding a
    # package dependency to get a ROM we would not use.
    exec timeout "$BOOT_BUDGET" qemu-system-aarch64 \
      -machine virt,gic-version=3 -accel tcg -m 2048 -smp 2 -cpu cortex-a72 -nographic \
      -kernel "$WORK/kernel_2712.img" -append "$CMDLINE" \
      -drive file="$IMG",format=raw,if=none,id=hd0 -device virtio-blk-pci,drive=hd0 \
      -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${HTTP_PORT}-:80,hostfwd=tcp:127.0.0.1:${HTTPS_PORT}-:443,hostfwd=udp:127.0.0.1:${DNS_PORT}-:53,hostfwd=tcp:127.0.0.1:${DNS_PORT}-:53" \
      -device virtio-net-pci,netdev=n0,romfile= \
      -serial mon:stdio > "$CONSOLE_LOG" 2>&1
    ;;
  esac
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
api=0 ui=0 NSUDP="" NSTCP="" RPID=""
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
    # Capture the api's WebAuthn RP ID while the VM is STILL RUNNING. It is
    # asserted further down with the console checks, but it can only be
    # COLLECTED here: everything below runs after the qemu kill, so an HTTP call
    # there talks to a dead machine and returns nothing — which reads exactly
    # like a failed derivation.
    # HTTPS because :80 is only the bootstrap/redirect surface; -k because the
    # leaf is signed by the per-installation Mesh CA. Unauthenticated on
    # purpose: first-user registration is open until a user exists, which is
    # this freshly-provisioned box.
    RPID=$(curl -sk --max-time 10 -X POST "https://127.0.0.1:${HTTPS_PORT}/api/auth/register/begin" \
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

TOTAL=$(( $(date +%s) - START ))

kill "$QPID" 2>/dev/null || true
echo "----- last 60 lines of console -----"; tail -60 "$CONSOLE_LOG" || true
echo "----- $ARCH smoke timings (seconds from qemu start) -----"
echo "multi-user=${MU_AT}s firstboot=${FB_AT}s api+ui+dns=${API_AT}s atrest-verdict=${ATREST_AT}s total(incl. 70s soak)=${TOTAL}s"

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
#   FAIL ...         a declared path is not its declared mode, a swept file is
#                    group- or world-accessible, a mode could not be read, or
#                    the inventory itself was unreadable.
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
  echo "::error::the at-rest mode audit FAILED on the booted machine — a path on the persistent partition is not the mode /usr/lib/rasputin/atrest/inventory declares for it, or a swept tree holds a group/world-accessible file. The verdict below carries the count and the FIRST offending path with its actual mode; the remaining findings are printed on the audit's stdout, which systemd captures into the guest's journal and which therefore does NOT reach this console — reproduce them with test/atrest-modes-test.sh or on a node. Either the mode regressed or the inventory is out of date — do not widen the inventory to match a widened file."
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
