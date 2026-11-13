"""A soft passkey: the authenticator's half of WebAuthn, ported from
geekdojo/geekdojo-brain#959.

Registration reuses test/lib/soft-passkey.py's `encode` (a "none"
attestation over a P-256 key), loaded by path, not copied. Assertions are
built here: authenticator data is sha256(rpId) || flags || counter, client
data is a `webauthn.get` JSON, and the signature over
authData || sha256(clientData) comes from openssl through OpensslPasskeys,
so Python never handles private-key bytes when signing.

The mutators each change one field of an assertion before it is signed (or,
for the signature, after), so each negative differs from a good assertion in
exactly the field it tests.
"""

import base64
import dataclasses
import hashlib
import importlib.util
import json
import os
import subprocess

from .errors import Inconclusive

FLAG_UP = 0x01
FLAG_UV = 0x04


def load_soft_passkey(path):
    """Load soft-passkey.py from its path; a missing or broken file is
    Inconclusive."""
    if not path or not os.path.isfile(path):
        raise Inconclusive(f"The soft passkey helper {path!r} does not exist.")
    try:
        spec = importlib.util.spec_from_file_location("soft_passkey", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    except Exception as err:  # noqa: BLE001 - any load failure is reported the same way
        raise Inconclusive(f"The soft passkey helper {path!r} could not be loaded "
                           f"({type(err).__name__}).") from err
    for name in ("encode", "b64url", "InputError"):
        if not hasattr(module, name):
            raise Inconclusive(f"The soft passkey helper {path!r} has no {name}.")
    return module


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def encode_registration(soft, options, origin, pubkey_der, credential_id):
    """soft-passkey's PublicKeyCredential for these creation options."""
    try:
        return soft.encode(options, origin, pubkey_der, credential_id)
    except soft.InputError as err:
        raise Inconclusive(f"The soft passkey refused the registration options: {err}") from err


def registration_fields(soft, args, origin, pubkey_der, credential_id, label):
    """The form fields Keycloak's webauthn-register page posts, built by the
    soft passkey from the page's own arguments."""
    options = {"publicKey": {"challenge": args["challenge"], "rp": {"id": args["rpId"]}}}
    credential = encode_registration(soft, options, origin, pubkey_der, credential_id)
    return {
        "clientDataJSON": credential["response"]["clientDataJSON"],
        "attestationObject": credential["response"]["attestationObject"],
        "publicKeyCredentialId": credential["rawId"],
        "authenticatorLabel": label,
        "transports": "internal",
        "authenticatorAttachment": "platform",
        "error": "",
    }


@dataclasses.dataclass(frozen=True)
class AssertionInputs:
    rp_id: str
    origin: str
    challenge: str
    credential_id: bytes
    user_handle: str
    flags: int = FLAG_UP | FLAG_UV
    counter: int = 0


@dataclasses.dataclass(frozen=True)
class Assertion:
    inputs: AssertionInputs
    authenticator_data: bytes
    client_data_json: bytes
    signature: bytes

    def fields(self):
        """The hidden inputs of Keycloak's `webauth` form."""
        return {
            "credentialId": b64url(self.inputs.credential_id),
            "clientDataJSON": b64url(self.client_data_json),
            "authenticatorData": b64url(self.authenticator_data),
            "signature": b64url(self.signature),
            "userHandle": self.inputs.user_handle,
            "error": "",
        }

    def credential(self):
        """The PublicKeyCredential JSON a WebAuthn library's finish step takes."""
        cid = b64url(self.inputs.credential_id)
        return {"id": cid, "rawId": cid, "type": "public-key", "response": {
            "clientDataJSON": b64url(self.client_data_json),
            "authenticatorData": b64url(self.authenticator_data),
            "signature": b64url(self.signature),
            "userHandle": self.inputs.user_handle}}


def authenticator_data(rp_id, flags, counter):
    return hashlib.sha256(rp_id.encode("utf-8")).digest() + bytes([flags]) + counter.to_bytes(4, "big")


def client_data_get(challenge, origin):
    return json.dumps({"type": "webauthn.get", "challenge": challenge, "origin": origin,
                       "crossOrigin": False}, separators=(",", ":")).encode("utf-8")


def signed_message(auth_data, client_data):
    return auth_data + hashlib.sha256(client_data).digest()


def build_assertion(inputs, signer):
    auth = authenticator_data(inputs.rp_id, inputs.flags, inputs.counter)
    client = client_data_get(inputs.challenge, inputs.origin)
    return Assertion(inputs, auth, client, signer.sign(signed_message(auth, client)))


def _corrupt(signature):
    # One bit flipped inside r, past the DER headers, so the signature still
    # parses as DER and fails only as a signature.
    index = min(10, len(signature) - 1)
    return signature[:index] + bytes([signature[index] ^ 0x01]) + signature[index + 1:]


MUTATORS = ("bad-origin", "bad-rpid", "no-up", "no-uv", "bad-challenge", "bad-signature")


def mutate(name, inputs, signer, other_door):
    """The assertion for negative `name`. `other_door` holds the origin and
    RP ID of the door the assertion does not belong to."""
    if name == "bad-origin":
        return build_assertion(dataclasses.replace(inputs, origin=other_door["origin"]), signer)
    if name == "bad-rpid":
        return build_assertion(dataclasses.replace(inputs, rp_id=other_door["rp_id"]), signer)
    if name == "no-up":
        return build_assertion(dataclasses.replace(inputs, flags=inputs.flags & ~FLAG_UP), signer)
    if name == "no-uv":
        return build_assertion(dataclasses.replace(inputs, flags=inputs.flags & ~FLAG_UV), signer)
    if name == "bad-challenge":
        wrong = b64url(hashlib.sha256(inputs.challenge.encode("ascii")).digest())
        return build_assertion(dataclasses.replace(inputs, challenge=wrong), signer)
    if name == "bad-signature":
        good = build_assertion(inputs, signer)
        return dataclasses.replace(good, signature=_corrupt(good.signature))
    raise Inconclusive(f"The client knows no assertion mutator named {name}.")


class _OpensslSigner:
    def __init__(self, key_path, run):
        self._key_path = key_path
        self._run = run

    def sign(self, message):
        if not os.path.isfile(self._key_path):
            raise Inconclusive("The passkey's private key file is missing, so it cannot sign.")
        result = _openssl(self._run, ["dgst", "-sha256", "-sign", self._key_path], message)
        if result.returncode != 0 or not result.stdout:
            raise Inconclusive("openssl could not sign the assertion.")
        return result.stdout


def _openssl(run, args, stdin=None):
    try:
        return run(["openssl", *args], input=stdin, capture_output=True, check=False)
    except FileNotFoundError as err:
        raise Inconclusive("openssl is not on PATH, so the client cannot make or use a passkey.") from err


class OpensslPasskeys:
    """P-256 key pairs and ES256 signatures from openssl. The private key
    stays in a 0600 file whose path is openssl's only argument; the message
    to sign goes over stdin."""

    def __init__(self, run=subprocess.run):
        self._run = run

    def make(self, key_path):
        """Make a key pair at key_path; return the public key as DER."""
        os.close(os.open(key_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600))
        made = _openssl(self._run, ["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key_path])
        if made.returncode != 0:
            raise Inconclusive("openssl could not make the passkey's key pair.")
        public = _openssl(self._run, ["ec", "-in", key_path, "-pubout", "-outform", "DER"])
        if public.returncode != 0 or not public.stdout:
            raise Inconclusive("openssl could not read the passkey's public key.")
        return public.stdout

    def signer(self, key_path):
        return _OpensslSigner(key_path, self._run)
