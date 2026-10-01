#!/bin/sh
# cred-test.sh: does this systemd deliver a key file through LoadCredential= and
# LoadCredentialEncrypted=? Spike geekdojo/geekdojo-brain#679, question 2.
#
# Runs AS ROOT on the system under test, with busybox applets only:
#   - on a bench node, staged by run.sh (systemd 256.17, the current image);
#   - inside a container booted from a Buildroot target tree, by the rasputin-os
#     spike workflow (systemd 256.17 as a control, and 258.7 from rasputin-os#87).
#
# usage: cred-test.sh <scratch dir that does not exist yet>
#
# Secrets: the key is 32 throwaway random bytes made here and deleted here. Only
# its length and the first 12 hex digits of its SHA-256 are printed, so the
# delivered copy can be matched to the source without printing it.
#
# Side effects, all undone before exit:
#   - transient units spike679-cred-*.service (run with --collect, so systemd
#     unloads them even when they fail);
#   - /var/lib/systemd/credential.secret, the host key, which
#     `systemd-creds encrypt --with-key=host` creates if it is absent. If it was
#     absent at the start it is deleted at the end; if it was present it is left
#     untouched.
set -u
W="${1:?usage: $0 <scratch dir>}"
HOSTKEY=/var/lib/systemd/credential.secret
U=spike679-cred
[ -e "$W" ] && { echo "refusing: $W exists" >&2; exit 2; }

if [ -e "$HOSTKEY" ]; then HK_BEFORE=present; else HK_BEFORE=absent; fi

cleanup() {
  for s in plain enc tpm2 null tamper; do
    systemctl stop "$U-$s.service" 2>/dev/null
    systemctl reset-failed "$U-$s.service" 2>/dev/null
  done
  rm -rf "$W"
  if [ "$HK_BEFORE" = absent ] && [ -e "$HOSTKEY" ]; then rm -f "$HOSTKEY"; fi
  echo "## cleanup"
  echo "scratch dir: $(ls -d "$W" 2>/dev/null || echo gone)"
  if [ -e "$HOSTKEY" ]; then echo "host key: present (was $HK_BEFORE)"; else echo "host key: absent (was $HK_BEFORE)"; fi
  echo "units left: $(systemctl list-units --all --no-legend "$U-*" | wc -l)"
}
trap cleanup EXIT

fp() { sha256sum "$1" | cut -c1-12; }
lsmode() { ls -ln "$1" | awk '{print "mode=" $1 " uid=" $3}'; }

echo "## systemd"
systemctl --version | head -2
echo "## systemd-creds has-tpm2"
systemd-creds has-tpm2 2>&1; echo "exit=$?"
echo "## host key before: $HK_BEFORE"

mkdir -m 0700 "$W"
head -c 32 /dev/urandom > "$W/seal.key"
chmod 0600 "$W/seal.key"
echo "## source key: bytes=$(wc -c < "$W/seal.key") sha256[0:12]=$(fp "$W/seal.key") $(lsmode "$W/seal.key")"

# What the service sees. Runs as nobody: the source file is root-only 0600 in a
# 0700 dir, so a successful read proves systemd delivered it, not the filesystem.
SHOW='echo "CREDENTIALS_DIRECTORY=$CREDENTIALS_DIRECTORY uid=$(id -u)"; ls -ln "$CREDENTIALS_DIRECTORY" | tail -n +2; echo "delivered: bytes=$(wc -c < "$CREDENTIALS_DIRECTORY/seal-key") sha256[0:12]=$(sha256sum "$CREDENTIALS_DIRECTORY/seal-key" | cut -c1-12)"'

run_unit() {  # $1 = suffix, $2 = property
  systemd-run --quiet --pipe --wait --collect --unit="$U-$1" -p User=nobody -p "$2" /bin/sh -c "$SHOW" 2>&1
  echo "exit=$?"
}

echo "## A. LoadCredential= (plain)"
run_unit plain "LoadCredential=seal-key:$W/seal.key"

echo "## B. systemd-creds encrypt --with-key=host"
systemd-creds encrypt --with-key=host --name=seal-key "$W/seal.key" "$W/seal.key.cred" 2>&1; echo "exit=$?"
if [ -e "$HOSTKEY" ]; then echo "host key now: present ($(lsmode "$HOSTKEY"))"; else echo "host key now: absent"; fi
echo "what backs /var/lib/systemd and / (the host key must be writable there):"
mount | awk '$3 == "/" || $3 ~ /^\/var\/lib\/systemd/ {print "  " $3 " " $5 " " $6}'

echo "## B. LoadCredentialEncrypted= (host key)"
if [ -s "$W/seal.key.cred" ]; then
  run_unit enc "LoadCredentialEncrypted=seal-key:$W/seal.key.cred"
else
  echo "skipped: no encrypted credential was produced"
fi

echo "## C. systemd-creds encrypt --with-key=tpm2 (this build has -TPM2)"
systemd-creds encrypt --with-key=tpm2 --name=seal-key "$W/seal.key" "$W/seal.key.tpm2" 2>&1; echo "exit=$?"
if [ -s "$W/seal.key.tpm2" ]; then
  echo "a blob was written: bytes=$(wc -c < "$W/seal.key.tpm2")"
  echo "## C. LoadCredentialEncrypted= with that tpm2 blob"
  run_unit tpm2 "LoadCredentialEncrypted=seal-key:$W/seal.key.tpm2"
fi
echo "## C2. systemd-creds encrypt --with-key=host+tpm2"
systemd-creds encrypt --with-key=host+tpm2 --name=seal-key "$W/seal.key" "$W/seal.key.htpm2" 2>&1; echo "exit=$?"

echo "## N. systemd-creds encrypt --with-key=null (no confidentiality, no authenticity)"
systemd-creds encrypt --with-key=null --name=seal-key "$W/seal.key" "$W/seal.key.null" 2>&1; echo "exit=$?"
if [ -s "$W/seal.key.null" ]; then
  echo "## N. LoadCredentialEncrypted= with the null-key blob"
  run_unit null "LoadCredentialEncrypted=seal-key:$W/seal.key.null"
fi

echo "## D. LoadCredentialEncrypted= with one byte of the host-key blob flipped (must refuse)"
if [ -s "$W/seal.key.cred" ]; then
  # Flip the last byte (inside the AES-GCM tag) with dd and od from busybox.
  n=$(wc -c < "$W/seal.key.cred")
  b=$(od -An -tu1 -j $((n - 1)) -N1 "$W/seal.key.cred" | tr -d ' ')
  cp "$W/seal.key.cred" "$W/seal.key.bad"
  printf "\\$(printf %o $(( (b ^ 1) & 255 )))" | dd of="$W/seal.key.bad" bs=1 seek=$((n - 1)) conv=notrunc 2>/dev/null
  run_unit tamper "LoadCredentialEncrypted=seal-key:$W/seal.key.bad"
else
  echo "skipped: no encrypted credential was produced"
fi
