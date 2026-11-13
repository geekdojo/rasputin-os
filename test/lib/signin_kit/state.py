"""The client's state directory: what a person's browser and authenticator
would keep between visits, and the needles file.

The directory must be 0700 and owned by the caller, or the run is
Inconclusive. Every file is written 0600. Each account is one JSON file;
each passkey's private key is a PEM file openssl writes. `needles` holds,
one per line, every secret the client made or received (passwords, the
authenticator-app secret, recovery codes, authorization codes, tokens,
session cookies, the private keys' base64 lines), for secret-scan.sh to
look for. A value shorter than MIN_NEEDLE (a six-digit one-time code) is not
kept: it matches by chance in any long log, and it is spent once used.
All of it is synthetic and dies with the directory, which the caller's trap
removes.
"""

import json
import os
import re
import stat

from .errors import Inconclusive

MIN_NEEDLE = 8
_LABEL = re.compile(r"^[a-z][a-z0-9-]{0,15}$")


def _write_0600(path, text):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


class State:
    def __init__(self, directory, uid):
        try:
            info = os.lstat(directory)
        except OSError as err:
            raise Inconclusive(f"The state directory {directory} does not exist.") from err
        if not stat.S_ISDIR(info.st_mode):
            raise Inconclusive(f"The state directory {directory} is not a directory.")
        if stat.S_IMODE(info.st_mode) != 0o700:
            raise Inconclusive(f"The state directory {directory} is mode "
                               f"{stat.S_IMODE(info.st_mode):04o}, not 0700.")
        if info.st_uid != uid:
            raise Inconclusive(f"The state directory {directory} is owned by uid {info.st_uid}, "
                               f"not this run's uid {uid}.")
        self._dir = directory
        self._needles_path = os.path.join(directory, "needles")
        self._needles = set()
        try:
            with open(self._needles_path, encoding="utf-8") as f:
                self._needles = {line for line in f.read().split("\n") if line}
        except FileNotFoundError:
            pass

    def _path(self, label, suffix):
        if not _LABEL.match(label or ""):
            raise Inconclusive(f"The account label {label!r} is not one the client accepts.")
        return os.path.join(self._dir, f"{label}.{suffix}")

    def key_path(self, label, purpose):
        return self._path(label, f"{purpose}.key")

    def load(self, label):
        path = self._path(label, "json")
        try:
            with open(path, encoding="utf-8") as f:
                return json.load(f)
        except FileNotFoundError as err:
            raise Inconclusive(f"The account {label} has not been created in this state directory.") from err
        except (OSError, ValueError) as err:
            raise Inconclusive(f"The state file for the account {label} could not be read.") from err

    def save(self, label, account):
        _write_0600(self._path(label, "json"), json.dumps(account, sort_keys=True))
        self.add_account_needles(account)

    def add_account_needles(self, account):
        values = [account.get(k) for k in ("password", "old_password", "totp_secret")]
        values += account.get("recovery_codes") or []
        values += list((account.get("tokens") or {}).values())
        self.add_needles(*values)

    def add_key_needles(self, key_path):
        """The base64 lines of a PEM private key, read from its file."""
        with open(key_path, encoding="ascii") as f:
            self.add_needles(*[ln.strip() for ln in f if ln.strip() and not ln.startswith("-----")])

    def add_needles(self, *values):
        new = {v for v in values if isinstance(v, str) and len(v) >= MIN_NEEDLE and "\n" not in v}
        if new - self._needles:
            self._needles |= new
            _write_0600(self._needles_path, "".join(v + "\n" for v in sorted(self._needles)))

    def needles(self):
        return set(self._needles)
