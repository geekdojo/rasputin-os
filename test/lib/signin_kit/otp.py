"""One-time codes: RFC 4226 HOTP and RFC 6238 TOTP. Pure: the time is
passed in."""

import base64
import hashlib
import hmac

ALGORITHMS = {"sha1": hashlib.sha1, "sha256": hashlib.sha256, "sha512": hashlib.sha512}


class SecretFormatError(ValueError):
    """The authenticator-app secret is not valid base32."""


def base32_secret(text):
    """Decode a base32 secret as an authenticator app reads it: spaces and
    case ignored, padding optional. A malformed value raises SecretFormatError."""
    cleaned = "".join(text.split()).upper().rstrip("=")
    if not cleaned or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567" for c in cleaned):
        raise SecretFormatError("The authenticator-app secret is not valid base32.")
    return base64.b32decode(cleaned + "=" * (-len(cleaned) % 8))


def hotp(key, counter, digits=6, algorithm="sha1"):
    """RFC 4226 section 5.3, with the hash of RFC 6238 section 1.2."""
    digest = hmac.new(key, counter.to_bytes(8, "big"), ALGORITHMS[algorithm]).digest()
    offset = digest[-1] & 0x0F
    value = int.from_bytes(digest[offset:offset + 4], "big") & 0x7FFFFFFF
    return str(value % (10 ** digits)).zfill(digits)


def totp_step(unix_time, period=30):
    return int(unix_time // period)


def totp(key, unix_time, digits=6, algorithm="sha1", period=30):
    """RFC 6238 section 4 at a given time."""
    return hotp(key, totp_step(unix_time, period), digits, algorithm)
