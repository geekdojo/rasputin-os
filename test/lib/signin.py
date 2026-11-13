#!/usr/bin/env python3
"""signin.py: the headless sign-in client for the OS smoke tests
(geekdojo/geekdojo-brain#967). One verb per run:

    signin.py create-account          --doors F --label L [--door home|app]
    signin.py enrol totp|passkey|passkey-2fa|recovery-codes   (same options)
    signin.py sign-in password|password-totp|password-passkey|passkey|recovery-code
    signin.py sign-out
    signin.py reset-password passkey
    signin.py negative bad-origin|bad-rpid|no-up|no-uv|bad-signature|bad-challenge|
                       replay|admin-password-alone|no-app-access|
                       pkce-wrong-verifier|pkce-absent
    signin.py legacy-register --base URL --name N
    signin.py legacy-sign-in  --base URL --name N

Every verb also takes --state DIR (0700, owned by the caller; files 0600)
and --ca FILE, and optionally --server-name, --connect ADDR:PORT,
--client-cert and --client-key, --timeout and --stock-theme. --doors names a
JSON file: {"home": {"origin", "realm", "client_id", "redirect_uri",
"post_logout_uri"}, "app": {...}}. No option takes a secret.

Stdout is exactly one line, `signin <verb> PASS|FAIL|INCONCLUSIVE <fact>`.
Exit 0: the fact held. 1: a named fact failed. 2: the run could not tell
(an unknown or missing page id, an empty page, no HTTP answer, TLS failing
against --ca, openssl missing, a bad state directory, bad arguments). It
never passes on absence. stderr carries `level= event=` lines and no secret.

Run with python3 -I. Standard library and openssl only. This file is the
composition root; the modules are in signin_kit/.
"""

import argparse
import http.cookiejar
import json
import os
import shutil
import sys
import time
import urllib.parse

# python3 -I leaves the script's own directory off sys.path; signin_kit,
# beside this file, is added back, and nothing else.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from signin_kit import flows, legacy, passkey  # noqa: E402
from signin_kit.errors import EXIT_FACT_FAILED, EXIT_PASS, Inconclusive, SigninError  # noqa: E402
from signin_kit.log import Log  # noqa: E402
from signin_kit.state import State  # noqa: E402
from signin_kit.transport import HttpsOpener, Transport, ssl_context  # noqa: E402

SOFT_PASSKEY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "soft-passkey.py")
WORDS = {EXIT_PASS: "PASS", EXIT_FACT_FAILED: "FAIL"}
LEGACY_VERBS = ("legacy-register", "legacy-sign-in")


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Inconclusive(f"Bad arguments: {message}.")


def build_parser():
    common = _Parser(add_help=False)
    common.add_argument("--state", required=True, help="the 0700 state directory")
    common.add_argument("--ca", required=True, help="the CA certificate the server must chain to")
    common.add_argument("--server-name", help="the SNI and certificate name (default: the URL's host)")
    common.add_argument("--connect", help="ADDR:PORT every connection goes to")
    common.add_argument("--client-cert", help="a client certificate to present, PEM")
    common.add_argument("--client-key", help="its key file")
    common.add_argument("--timeout", type=float, default=30, help="seconds per HTTP call")
    common.add_argument("--stock-theme", action="store_true",
                        help="accept pages without the Rasputin theme marker")
    common.add_argument("--soft-passkey", default=SOFT_PASSKEY, help=argparse.SUPPRESS)
    keycloak = _Parser(add_help=False, parents=[common])
    keycloak.add_argument("--doors", required=True, help="the doors' JSON file")
    keycloak.add_argument("--label", required=True, help="the account label")
    keycloak.add_argument("--door", choices=("home", "app"), default="home")
    old = _Parser(add_help=False, parents=[common])
    old.add_argument("--base", required=True, help="the console's https:// base URL")
    old.add_argument("--name", required=True, help="the operator's name")

    parser = _Parser(prog="signin.py", description="The headless sign-in client.")
    verbs = parser.add_subparsers(dest="verb", required=True, parser_class=_Parser)
    verbs.add_parser("create-account", parents=[keycloak])
    verbs.add_parser("enrol", parents=[keycloak]).add_argument("what", choices=sorted(flows.ENROL_ACTIONS))
    verbs.add_parser("sign-in", parents=[keycloak]).add_argument("what", choices=flows.SIGN_IN_METHODS)
    verbs.add_parser("sign-out", parents=[keycloak])
    verbs.add_parser("reset-password", parents=[keycloak]).add_argument("what", choices=("passkey",))
    verbs.add_parser("negative", parents=[keycloak]).add_argument("what", choices=sorted(flows.NEGATIVES))
    for verb in LEGACY_VERBS:
        verbs.add_parser(verb, parents=[old])
    return parser


def load_doors(path):
    try:
        with open(path, encoding="utf-8") as f:
            raw = json.load(f)
        return {name: flows.Door(name, d["origin"], d["realm"], d["client_id"], d["redirect_uri"],
                                 d["post_logout_uri"]) for name, d in raw.items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError) as err:
        raise Inconclusive(f"The doors file {path} could not be read ({type(err).__name__}).") from err


def connect_address(value):
    if not value:
        return None
    host, sep, port = value.rpartition(":")
    if not sep or not host or not port.isdigit():
        raise Inconclusive(f"Bad arguments: --connect {value} is not ADDR:PORT.")
    return host, int(port)


def https_opener(args):
    """The production opener factory."""
    return HttpsOpener(ssl_context(args.ca, args.client_cert, args.client_key),
                       connect_address(args.connect), args.server_name, args.timeout)


def run_verb(args, clock, rng, passkeys, opener_factory, state, log, trace):
    soft = passkey.load_soft_passkey(args.soft_passkey)
    jar = http.cookiejar.CookieJar()
    if args.verb in LEGACY_VERBS:
        base = args.base.rstrip("/")
        transport = Transport(opener_factory(args), {urllib.parse.urlsplit(base).hostname}, jar, state, log)
        old = legacy.Legacy(transport, state, soft, passkeys, rng, jar)
        return old.register(base, args.name) if args.verb == "legacy-register" else old.sign_in(base, args.name)
    doors = load_doors(args.doors)
    transport = Transport(opener_factory(args), {d.host for d in doors.values()}, jar, state, log)
    verbs = flows.Flows(transport, doors, state, soft, passkeys, clock, rng, log)
    detail = ""
    if args.verb == "create-account":
        verbs.create_account(trace, args.label, args.door)
    elif args.verb == "enrol":
        verbs.enrol(trace, args.what, args.label, args.door)
    elif args.verb == "sign-in":
        verbs.sign_in(trace, args.what, args.label, args.door)
    elif args.verb == "sign-out":
        verbs.sign_out(trace, args.label, args.door)
    elif args.verb == "reset-password":
        verbs.reset_password_passkey(trace, args.label, args.door)
    else:
        detail = f"refused: {verbs.negative(trace, args.what, args.label, args.door)}; "
    return f"{detail}pages={','.join(trace.page_ids) or '-'}"


def main(argv, env, stdout, stderr, clock, rng, signer_factory, opener_factory):
    """Run one verb; print its one stdout line; return its exit code."""
    verb = argv[0] if argv and not argv[0].startswith("-") else "-"
    held = {}
    log = Log(stderr, lambda: held["state"].needles() if "state" in held else set())
    trace = None
    try:
        args = build_parser().parse_args(argv)
        trace = flows.Trace(args.stock_theme)
        if shutil.which("openssl", path=env.get("PATH", "")) is None:
            raise Inconclusive("openssl is not on PATH, so the client cannot make or use a passkey.")
        held["state"] = State(args.state, os.getuid())
        log.info("start", verb=verb)
        fact = run_verb(args, clock, rng, signer_factory(), opener_factory, held["state"], log, trace)
        code = EXIT_PASS
    except SigninError as err:
        code, fact = err.exit_code, err.sentence
    except Exception as err:  # noqa: BLE001 - an unforeseen error is never a pass or a failed fact
        code, fact = 2, f"The client stopped on an unexpected {type(err).__name__}."
    pages_seen = ",".join(trace.page_ids) if trace else ""
    log.emit("info" if code == EXIT_PASS else "error", "end", verb=verb, exit=code, pages=pages_seen or "-")
    stdout.write(f"signin {verb} {WORDS.get(code, 'INCONCLUSIVE')} {fact}\n")
    stdout.flush()
    return code


class Clock:
    def now(self):
        return time.time()

    def sleep_until(self, when):
        delay = when - time.time()
        if delay > 0:
            time.sleep(delay)


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main(sys.argv[1:], os.environ, sys.stdout, sys.stderr, Clock(), os.urandom,
                  passkey.OpensslPasskeys, https_opener))
