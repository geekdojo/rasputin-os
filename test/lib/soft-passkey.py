#!/usr/bin/env python3
"""soft-passkey.py: the browser's half of a WebAuthn registration, for tests.

The boot smoke signs in to a fresh control plane through first-run
registration (geekdojo/geekdojo-brain#834, test/lib/api-session.sh). This
helper turns the api's register/begin options into the PublicKeyCredential
that register/finish takes, as a browser would after an authenticator made a
key: a "none" attestation, which carries no signature, over a P-256 public key
made by openssl. It holds no private key and uses no cryptographic primitive
but SHA-256 of the RP ID; the api's vetted WebAuthn library is the verifier.

    python3 -I soft-passkey.py --origin ORIGIN --pubkey-der FILE \
        [--credential-id HEX] < begin-options.json > credential.json

The options are read from stdin in the shape register/begin sends them,
{"publicKey": {"challenge": ..., "rp": {"id": ...}, ...}}. Bad input exits 2
with nothing on stdout and one sentence on stderr. Standard library only.
"""

import argparse
import base64
import hashlib
import json
import os
import sys

# A P-256 SubjectPublicKeyInfo is this 26-byte header, then the uncompressed
# point: 0x04, x (32 bytes) and y (32 bytes). Bytes 0-1 are the outer
# SEQUENCE's tag and length; the rest names id-ecPublicKey on prime256v1.
_P256_SPKI_HEADER = bytes.fromhex(
    "3059301306072a8648ce3d020106082a8648ce3d030107034200")
_P256_SPKI_LEN = len(_P256_SPKI_HEADER) + 65

# Authenticator data flags: user present, user verified, attested credential
# data included (WebAuthn Level 2, section 6.1).
_FLAGS = 0x01 | 0x04 | 0x40


class InputError(Exception):
    """Input the helper refuses; its message is the sentence for stderr."""


def b64url(data):
    """Unpadded base64url, the encoding WebAuthn uses on the wire."""
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _cbor_head(major, n):
    if n < 24:
        return bytes([major << 5 | n])
    if n < 0x100:
        return bytes([major << 5 | 24, n])
    return bytes([major << 5 | 25]) + n.to_bytes(2, "big")


def cbor(value):
    """CBOR for the types an attestation object needs, keys in the given order."""
    if isinstance(value, int):
        if value >= 0:
            return _cbor_head(0, value)
        return _cbor_head(1, -1 - value)
    if isinstance(value, bytes):
        return _cbor_head(2, len(value)) + value
    if isinstance(value, str):
        raw = value.encode("utf-8")
        return _cbor_head(3, len(raw)) + raw
    out = _cbor_head(5, len(value))
    for key, item in value.items():
        out += cbor(key) + cbor(item)
    return out


def p256_point(pubkey_der):
    """The x and y coordinates from a P-256 public key's DER."""
    if pubkey_der[2:len(_P256_SPKI_HEADER)] != _P256_SPKI_HEADER[2:]:
        raise InputError("The public key is not a P-256 key.")
    if len(pubkey_der) != _P256_SPKI_LEN:
        raise InputError("The public key is the wrong length for a P-256 key.")
    return pubkey_der[-64:-32], pubkey_der[-32:]


def encode(options, origin, pubkey_der, credential_id):
    """The PublicKeyCredential register/finish takes, for these options."""
    public_key = options.get("publicKey") if isinstance(options, dict) else None
    if not isinstance(public_key, dict):
        public_key = {}
    challenge = public_key.get("challenge")
    if not isinstance(challenge, str) or not challenge:
        raise InputError("The registration options carry no challenge.")
    rp = public_key.get("rp")
    rp_id = rp.get("id") if isinstance(rp, dict) else None
    if not isinstance(rp_id, str) or not rp_id:
        raise InputError("The registration options carry no rp.id.")
    x, y = p256_point(pubkey_der)

    client_data = json.dumps(
        {"type": "webauthn.create", "challenge": challenge, "origin": origin},
        separators=(",", ":")).encode("utf-8")
    # COSE_Key: kty EC2 (2), alg ES256 (-7), crv P-256 (1), x, y (RFC 9053).
    cose_key = cbor({1: 2, 3: -7, -1: 1, -2: x, -3: y})
    auth_data = (hashlib.sha256(rp_id.encode("utf-8")).digest()
                 + bytes([_FLAGS])
                 + bytes(4)        # signature counter
                 + bytes(16)       # AAGUID
                 + len(credential_id).to_bytes(2, "big")
                 + credential_id
                 + cose_key)
    attestation = cbor({"fmt": "none", "attStmt": {}, "authData": auth_data})
    return {
        "id": b64url(credential_id),
        "rawId": b64url(credential_id),
        "type": "public-key",
        "response": {
            "clientDataJSON": b64url(client_data),
            "attestationObject": b64url(attestation),
        },
    }


def main(argv, stdin, stdout, stderr, random_bytes):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--origin", required=True)
    parser.add_argument("--pubkey-der", required=True)
    parser.add_argument("--credential-id")
    args = parser.parse_args(argv)
    try:
        try:
            options = json.load(stdin)
        except ValueError:
            raise InputError("The options are not JSON.") from None
        try:
            with open(args.pubkey_der, "rb") as f:
                pubkey_der = f.read()
        except OSError:
            raise InputError("The public key file could not be read.") from None
        if args.credential_id is None:
            credential_id = random_bytes(16)
        else:
            try:
                credential_id = bytes.fromhex(args.credential_id)
            except ValueError:
                raise InputError("The credential id is not hex.") from None
        credential = encode(options, args.origin, pubkey_der, credential_id)
    except InputError as err:
        print(err, file=stderr)
        return 2
    json.dump(credential, stdout)
    stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdin, sys.stdout, sys.stderr, os.urandom))
