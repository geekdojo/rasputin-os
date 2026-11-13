"""PKCE, method S256 (RFC 7636). Pure: the random bytes are passed in."""

import base64
import hashlib


def challenge(verifier):
    """RFC 7636 section 4.2, method S256."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")


def verifier(random_bytes):
    """A 43-character verifier from 32 random bytes (RFC 7636 section 4.1)."""
    return base64.urlsafe_b64encode(random_bytes(32)).rstrip(b"=").decode("ascii")
