#!/usr/bin/env python3
"""Unit tests for test/lib/signin.py, the headless sign-in client
(geekdojo/geekdojo-brain#967, TC-967-01 to TC-967-05).

    SIGNIN_VECTORS=<dir> python3 -I test/signin-test.py

SIGNIN_VECTORS names rasputin-control-plane's
api/internal/identitytest/testdata/ (signin-vectors.json and pages/),
fetched at the pinned cp tag by test/signin-vectors-test.sh, which also runs
this suite under python3 -m trace for TC-967-06. Without it the vector
cases fail; nothing is skipped.

Fakes stand in for Keycloak (an opener that serves the fixture pages in each
step's order and checks every post against the vector's forms) and for the
old console api (a loopback TLS server, its certificate minted by openssl
under a test CA, that verifies each assertion with `openssl dgst -verify`).
Every key is made by openssl at run time; no key or seed literal is in this
file.
"""

import atexit
import base64
import hashlib
import http.server
import io
import json
import os
import shutil
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, "lib")
sys.path.insert(0, LIB)

import signin  # noqa: E402
from signin_kit import otp, pages, passkey, pkce  # noqa: E402
from signin_kit.errors import FactFailed, Inconclusive  # noqa: E402
from signin_kit.state import State  # noqa: E402

VECTORS = os.environ.get("SIGNIN_VECTORS", "")
LINE = r"^signin [a-z-]+ (PASS|FAIL|INCONCLUSIVE) \S.*\n$"


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_vectors():
    path = os.path.join(VECTORS, "signin-vectors.json")
    if not VECTORS or not os.path.isfile(path):
        raise AssertionError(f"SIGNIN_VECTORS={VECTORS!r} holds no signin-vectors.json; "
                             "test/signin-vectors-test.sh fetches it at the pinned cp tag.")
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def fixture(rel):
    with open(os.path.join(VECTORS, rel), "rb") as f:
        return f.read()


class FixedClock:
    def __init__(self, now=1_800_000_000.0):
        self.t = now

    def now(self):
        return self.t

    def sleep_until(self, when):
        self.t = max(self.t, when)


def seeded_rng():
    counter = [0]

    def rng(n):
        out = b""
        while len(out) < n:
            counter[0] += 1
            out += hashlib.sha256(b"signin-test-%d" % counter[0]).digest()
        return out[:n]
    return rng


class RecordingPasskeys:
    """openssl's keys and signatures, with every signed message recorded."""

    def __init__(self):
        self.real = passkey.OpensslPasskeys()
        self.messages = []

    def make(self, key_path):
        return self.real.make(key_path)

    def signer(self, key_path):
        real = self.real.signer(key_path)
        outer = self

        class _Signer:
            def sign(self, message):
                outer.messages.append(message)
                return real.sign(message)
        return _Signer()


def run(argv, opener=None, env=None, passkeys=None, clock=None, rng=None, opener_factory=None):
    """main() in-process: (exit code, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    code = signin.main(argv, env if env is not None else os.environ, out, err, clock or FixedClock(),
                       rng or seeded_rng(), (lambda: passkeys) if passkeys else passkey.OpensslPasskeys,
                       opener_factory or (lambda args: opener))
    return code, out.getvalue(), err.getvalue()


def state_dir(test):
    d = tempfile.mkdtemp(prefix="signin-state-")
    os.chmod(d, 0o700)
    test.addCleanup(shutil.rmtree, d, True)
    return d


CLEANUP = []
atexit.register(lambda: [shutil.rmtree(d, True) for d in CLEANUP])


def write_doors(_state=None):
    """The doors file, outside the state directory (whose files are all the
    client's own); it is removed at exit."""
    CLEANUP.append(tempfile.mkdtemp(prefix="signin-doors-"))
    path = os.path.join(CLEANUP[-1], "doors.json")
    door = {"realm": "rasputin", "client_id": "rasputin-console",
            "redirect_uri": "https://console.kc959.local/callback",
            "post_logout_uri": "https://console.kc959.local/signed-out"}
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"home": dict(door, origin="https://sso-kc959.local:19591"),
                   "app": dict(door, origin="https://signin.kc959.internal:19591", client_id="test-app",
                               redirect_uri="https://app.kc959.internal/callback",
                               post_logout_uri="https://app.kc959.internal/signed-out")}, f)
    return path


# --------------------------------------------------------------- Keycloak fake


class KeycloakFake:
    """An opener standing in for Keycloak. Each step is scripted with the
    page bodies it must see; every authorization request and form post takes
    the next body, and once they are spent, or at a None in the script, the
    next one redirects to the client with a code. The token endpoint checks the PKCE verifier against
    the challenge (S256). Posts are checked against `forms` (page id ->
    [(form id, field names)]) when given."""

    def __init__(self, forms=None):
        self.forms = forms
        self.queue = []
        self.served = []
        self.current = None
        self.codes = {}
        self.pending = None
        self.post_errors = []
        self.posted_forms = []
        self.counter = 0

    def script(self, bodies):
        self.queue = list(bodies)
        self.served = []

    def _redirect(self, location):
        return 302, [("Location", location)], b""

    def _next(self):
        if self.queue and self.queue[0] is None:
            self.queue.pop(0)
        elif self.queue:
            body = self.queue.pop(0)
            self.current = pages.parse(body.decode("utf-8"), stock_theme=True) if body.strip() and \
                b"data-page-id" in body and pages.page_id(body.decode()) else None
            self.served.append(self.current.page_id if self.current else "?")
            self.counter += 1
            return 200, [("Content-Type", "text/html"),
                         ("Set-Cookie", f"KC_RESTART=restart-cookie-{self.counter:08d}; Path=/; Secure")], body
        self.counter += 1
        code = f"code-{self.counter:08d}-{os.urandom(4).hex()}"
        self.codes[code] = self.pending["challenge"]
        return self._redirect(self.pending["redirect_uri"] + "?" + urllib.parse.urlencode(
            {"code": code, "state": self.pending["state"]}))

    def _check_post(self, url, fields):
        if self.current is None:
            self.post_errors.append(f"a post to {url} with no page served")
            return
        same_action = [f for f in self.current.forms if f.action == url]
        if not same_action:
            self.post_errors.append(f"a post to an action no form on {self.current.page_id} has")
            return
        if self.forms is None:
            return
        want = self.forms.get(self.current.page_id, [])
        matched = [fid for fid, names in want if set(names) <= set(fields)
                   and any(f.id == fid for f in same_action)]
        if not matched:
            self.post_errors.append(f"the post on {self.current.page_id} carries {sorted(fields)}, "
                                    f"not a form of the vector's")
        else:
            self.posted_forms.append((self.current.page_id, matched[0]))

    def __call__(self, method, url, headers, body):
        split = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(split.query))
        form = dict(urllib.parse.parse_qsl(body.decode(), keep_blank_values=True)) if body else {}
        if split.path.endswith("/protocol/openid-connect/auth"):
            self.pending = {"redirect_uri": query["redirect_uri"], "state": query["state"],
                            "challenge": query.get("code_challenge")}
            if not query.get("code_challenge"):
                return self._redirect(query["redirect_uri"] + "?error=invalid_request&state=" + query["state"])
            return self._next()
        if split.path.endswith("/protocol/openid-connect/logout"):
            return self._redirect(query["post_logout_redirect_uri"])
        if split.path.endswith("/protocol/openid-connect/token"):
            challenge = self.codes.pop(form.get("code"), None)
            if challenge is None or pkce.challenge(form.get("code_verifier", "")) != challenge:
                return 400, [], json.dumps({"error": "invalid_grant"}).encode()
            claims = b64url(json.dumps({"sub": "user-1"}).encode())
            self.counter += 1
            return 200, [], json.dumps({
                "access_token": f"access-token-{self.counter:08d}", "refresh_token": f"refresh-token-{self.counter:08d}",
                "id_token": f"eyJhbGciOiJub25lIn0.{claims}.id-token-{self.counter:08d}"}).encode()
        if method == "POST":
            self._check_post(url, form)
            return self._next()
        return 404, [], b"not found"


def label_for(step):
    head = step.split(".")[0]
    if head in ("FL4", "N1", "N2", "N3", "N4", "N5", "N6", "N7", "FL7n"):
        return "b"
    return {"N8": "c", "N9": "d"}.get(head, "a")


# ------------------------------------------------------------------ TC-967-01


class VectorReplay(unittest.TestCase):
    """TC-967-01: the vector file's flows replay; pages, forms, PKCE, TOTP and
    WebAuthn match the file."""

    @classmethod
    def setUpClass(cls):
        cls.v = load_vectors()
        cls.forms = {p["id"]: [(f["id"], f["fields"]) for f in p["forms"]] for p in cls.v["pages"]}
        cls.bodies = {p["id"]: fixture(p["fixture"]) for p in cls.v["pages"]}
        cls.state = tempfile.mkdtemp(prefix="signin-replay-")
        os.chmod(cls.state, 0o700)
        cls.doors = write_doors(cls.state)
        cls.fake = KeycloakFake(cls.forms)
        cls.passkeys = RecordingPasskeys()
        cls.clock, cls.rng = FixedClock(), seeded_rng()
        cls.results, cls.skipped, cls.outputs = [], [], []
        for flow in cls.v["flows"]:
            if flow["verb"] == "grant":
                cls.skipped.append(flow["step"])
                continue
            script = [cls.bodies[p] for p in flow["page_ids"]]
            if flow["verb"] == "reset-password":
                # The new password's post ends the first sign-in with a code;
                # the refused old password and the new sign-in follow.
                script.insert(2, None)
            cls.fake.script(script)
            argv = [flow["verb"], *flow["args"], "--state", cls.state, "--ca", "/unused", "--doors", cls.doors,
                    "--label", label_for(flow["step"]), "--door", flow["door"], "--stock-theme"]
            code, out, err = run(argv, cls.fake, passkeys=cls.passkeys, clock=cls.clock, rng=cls.rng)
            cls.results.append((flow, code, out, list(cls.fake.served)))
            cls.outputs.append(out + err)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.state, True)

    def test_every_step_sees_its_pages(self):
        self.assertEqual(len(self.results) + len(self.skipped), len(self.v["flows"]))
        for flow, code, out, served in self.results:
            with self.subTest(step=flow["step"]):
                self.assertEqual(code, 0, out)
                self.assertRegex(out, LINE)
                self.assertIn(" PASS ", out)
                self.assertTrue(out.rstrip().endswith("pages=" + (",".join(flow["page_ids"]) or "-")), out)
                self.assertEqual(served, flow["page_ids"])
                print(f"replay {flow['step']} PASS", file=sys.stderr)

    def test_posts_are_the_pages_own_forms(self):
        self.assertEqual(self.fake.post_errors, [])
        self.assertGreater(len(self.fake.posted_forms), 20)

    def test_skipped_steps_are_the_grant_steps(self):
        # grant is the api's; the client has no grant verb.
        self.assertEqual(self.skipped, [f["step"] for f in self.v["flows"] if f["verb"] == "grant"])
        self.assertIn("FL9.grant", self.skipped)
        print(f"replay skipped {self.skipped}", file=sys.stderr)

    def test_fixtures_hash_and_parse_to_the_vector(self):
        self.assertEqual(len(self.v["pages"]), len(pages.KNOWN_PAGES))
        for p in self.v["pages"]:
            with self.subTest(page=p["id"]):
                body = self.bodies[p["id"]]
                self.assertEqual(hashlib.sha256(body).hexdigest(), p["sha256"])
                page = pages.parse(body.decode(), stock_theme=True)
                self.assertEqual(page.page_id, p["id"])
                self.assertEqual([(f.id, sorted(f.fields)) for f in page.forms],
                                 [(f["id"], f["fields"]) for f in p["forms"]])

    def test_pkce_is_rfc7636(self):
        self.assertEqual(pkce.challenge(self.v["pkce_rfc7636"]["verifier"]), self.v["pkce_rfc7636"]["challenge"])
        self.assertEqual(len(pkce.verifier(os.urandom)), 43)

    def test_totp_is_rfc6238(self):
        t = self.v["totp_rfc6238"]
        self.assertTrue(t["cases"])
        for at, alg, want in t["cases"]:
            n = t["key_bytes"][alg]
            key = (t["seed_ascii"] * (n // len(t["seed_ascii"]) + 1))[:n].encode("ascii")
            with self.subTest(at=at, alg=alg):
                self.assertEqual(otp.totp(key, at, t["digits"], alg, t["period"]), want)
        secret = base64.b32encode(t["seed_ascii"].encode()).decode()
        self.assertEqual(otp.base32_secret(secret.lower()), t["seed_ascii"].encode())
        with self.assertRaises(otp.SecretFormatError):
            otp.base32_secret("not base32!")

    def test_assertion_signed_message(self):
        a = self.v["webauthn"]["assertion"]
        auth = passkey.authenticator_data(a["rp_id"], a["flags"], a["counter"])
        client = passkey.client_data_get(a["challenge"], a["origin"])
        self.assertEqual(auth.hex(), a["authenticator_data_hex"])
        self.assertEqual(client.decode(), a["client_data_json"])
        self.assertEqual(passkey.signed_message(auth, client).hex(), a["signed_message_hex"])

        class Recorder:
            message = None

            def sign(self, m):
                Recorder.message = m
                return b"\x30\x06\x02\x01\x01\x02\x01\x01"
        inputs = passkey.AssertionInputs(a["rp_id"], a["origin"], a["challenge"], b"\x01", "u", a["flags"], a["counter"])
        passkey.build_assertion(inputs, Recorder())
        self.assertEqual(Recorder.message.hex(), a["signed_message_hex"])
        # The replay's own assertions are signed over exactly this construction.
        self.assertTrue(self.passkeys.messages)
        for m in self.passkeys.messages:
            self.assertEqual(len(m), 37 + 32)

    def test_registration_fields(self):
        r = self.v["webauthn"]["registration"]
        soft = passkey.load_soft_passkey(signin.SOFT_PASSKEY)
        fields = passkey.registration_fields(
            soft, {"challenge": r["challenge"], "rpId": r["rp_id"]}, r["origin"],
            bytes.fromhex(r["pubkey_der_hex"]), bytes.fromhex(r["credential_id_hex"]), "label")
        self.assertEqual(sorted(fields), sorted(r["form_fields"]))
        self.assertEqual(fields["clientDataJSON"], r["client_data_json_b64url"])
        self.assertEqual(fields["attestationObject"], r["attestation_object_b64url"])
        self.assertEqual(fields["publicKeyCredentialId"], r["credential_id_b64url"])

    # TC-967-04, on the replay's pass paths: no needle in any output.
    def test_tc_967_04_no_needle_in_replay_output(self):
        with open(os.path.join(self.state, "needles"), encoding="utf-8") as f:
            needles = [n for n in f.read().split("\n") if n]
        self.assertGreater(len(needles), 10)
        text = "".join(self.outputs)
        self.assertEqual([n for n in needles if n in text], [])

    # TC-967-04: every file the client wrote is 0600.
    def test_tc_967_04_state_files_are_0600(self):
        names = os.listdir(self.state)
        self.assertIn("needles", names)
        for name in names:
            with self.subTest(file=name):
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.state, name)).st_mode), 0o600)

    # TC-967-04, the fail paths: every verb, served an error page where it
    # expects its own, fails (exit 1) with no needle in stdout or stderr.
    def test_tc_967_04_fail_paths_print_no_needle(self):
        copy = tempfile.mkdtemp(prefix="signin-fail-")
        self.addCleanup(shutil.rmtree, copy, True)
        shutil.copytree(self.state, copy, dirs_exist_ok=True)
        os.chmod(copy, 0o700)
        fake = KeycloakFake()
        verbs = [["create-account"], ["sign-in", "password"], ["sign-in", "password-totp"],
                 ["sign-in", "passkey"], ["sign-in", "recovery-code"], ["enrol", "totp"],
                 ["enrol", "passkey"], ["reset-password", "passkey"], ["negative", "bad-signature"]]
        outputs = []
        for verb in verbs:
            fake.script([self.bodies["login-error"]] * 3)
            label = "b" if verb[0] == "negative" else "a"
            code, out, err = run(verb + ["--state", copy, "--ca", "/unused", "--doors", self.doors,
                                         "--label", label, "--stock-theme"], fake)
            with self.subTest(verb=verb):
                self.assertEqual(code, 1, out)
                self.assertRegex(out, LINE)
            outputs.append(out + err)
        fake.script([])
        fake.codes.clear()
        code, out, err = run(["sign-out", "--state", copy, "--ca", "/unused", "--doors", self.doors,
                              "--label", "c", "--stock-theme"], fake)
        outputs.append(out + err)
        with open(os.path.join(copy, "needles"), encoding="utf-8") as f:
            needles = [n for n in f.read().split("\n") if n]
        self.assertEqual([n for n in needles if n in "".join(outputs)], [])


# ------------------------------------------------------------------ TC-967-02

KC_ARGS = ["--ca", "/unused", "--label", "a"]


def page(page_id, theme=False, extra=""):
    marker = ' data-rasputin-theme="rasputin"' if theme else ""
    return (f'<html><body data-page-id="{page_id}"{marker}>'
            '<form id="kc-register-form" action="https://sso-kc959.local:19591/realms/rasputin/login-actions/registration" '
            f'method="post"><input name="username"><input name="email"><input name="password">'
            f'<input name="password-confirm"></form>{extra}</body></html>').encode()


class PageIdentification(unittest.TestCase):
    """TC-967-02."""

    def go(self, body, *extra):
        fake = KeycloakFake()
        fake.script([body])
        d = state_dir(self)
        return run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS, *extra], fake)

    def test_unknown_page_id_is_inconclusive_naming_it(self):
        code, out, _ = self.go(page("login-new-thing", theme=True))
        self.assertEqual(code, 2)
        self.assertTrue(out.startswith("signin create-account INCONCLUSIVE "), out)
        self.assertIn("login-new-thing", out)

    def test_no_page_id_is_inconclusive(self):
        code, out, _ = self.go(b"<html><body><p>hello</p></body></html>")
        self.assertEqual(code, 2)
        self.assertIn("no data-page-id", out)

    def test_missing_theme_marker_fails_naming_it(self):
        code, out, _ = self.go(page("login-register"))
        self.assertEqual(code, 1)
        self.assertTrue(out.startswith("signin create-account FAIL "), out)
        self.assertIn("data-rasputin-theme", out)

    def test_stock_theme_proceeds(self):
        code, out, _ = self.go(page("login-register"), "--stock-theme")
        self.assertEqual(code, 0, out)
        self.assertIn("pages=login-register", out)

    def test_theme_marker_present_proceeds(self):
        code, out, _ = self.go(page("login-register", theme=True))
        self.assertEqual(code, 0, out)


# ------------------------------------------------------------------ TC-967-03 / 05 PKI


def sh_pki(script, *args):
    subprocess.run(["sh", "-c", f'. "{LIB}/test-pki.sh"; {script}', "sh", *args], check=True)


_PKI = {}


def pki():
    """The test CA, a server leaf for IP 127.0.0.1 under it, and a second CA
    it does not chain to, minted once by test-pki.sh; removed at exit."""
    if not _PKI:
        d = tempfile.mkdtemp(prefix="signin-pki-")
        CLEANUP.append(d)
        p = lambda n: os.path.join(d, n)  # noqa: E731
        sh_pki('mint_ca "$1" "$2" signin-test-ca && mint_leaf "$3" "$4" signin-test-api "$2" "$1" serverAuth IP:127.0.0.1'
               ' && mint_ca "$5" "$6" signin-other-ca',
               p("ca.key"), p("ca.pem"), p("api.key"), p("api.pem"), p("other.key"), p("other.pem"))
        _PKI.update(ca=p("ca.pem"), other=p("other.pem"), cert=p("api.pem"), key=p("api.key"))
    return _PKI


def closed_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# ------------------------------------------------------------- the old api fake

RP_ID = "updsmoke.local"


class OldApi(http.server.ThreadingHTTPServer):
    """The pre-identity console's auth routes over TLS, verifying each
    assertion with openssl against the key the registration carried."""

    def __init__(self):
        super().__init__(("127.0.0.1", 0), _OldApiHandler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(pki()["cert"], pki()["key"])
        self.socket = ctx.wrap_socket(self.socket, server_side=True)
        self.work = tempfile.mkdtemp(prefix="old-api-")
        self.users, self.pending, self.sessions = {}, {}, {}
        self.verify_log = []
        self.login_finish_status = None
        self.routes_404 = False
        self.me_status = None
        self.me_name = None
        threading.Thread(target=self.serve_forever, daemon=True).start()

    @property
    def base(self):
        return f"https://127.0.0.1:{self.server_address[1]}"

    def stop(self):
        self.shutdown()
        self.server_close()
        shutil.rmtree(self.work, True)

    def verify(self, pub_der, signature, message):
        paths = [os.path.join(self.work, n) for n in ("pub.der", "sig", "msg")]
        for path, data in zip(paths, (pub_der, signature, message)):
            with open(path, "wb") as f:
                f.write(data)
        r = subprocess.run(["openssl", "dgst", "-sha256", "-verify", paths[0], "-keyform", "DER",
                            "-signature", paths[1], paths[2]], capture_output=True, text=True)
        self.verify_log.append(r.stdout.strip())
        return r.returncode == 0


def _cookie(handler, name):
    for part in (handler.headers.get("Cookie") or "").split(";"):
        k, _, v = part.strip().partition("=")
        if k == name:
            return v
    return None


def _decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class _OldApiHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, obj=None, cookies=()):
        body = json.dumps(obj or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for c in cookies:
            self.send_header("Set-Cookie", c + "; Path=/; Secure; HttpOnly")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def begin(self, kind, extra):
        token, challenge = os.urandom(16).hex(), b64url(os.urandom(16))
        self.server.pending[token] = (kind, challenge, extra)
        return token, challenge

    def take(self, kind):
        p = self.server.pending.pop(_cookie(self, "rasputin-pending") or "", None)
        return p if p and p[0] == kind else None

    def client_data_ok(self, response, kind, challenge):
        cd = json.loads(_decode(response["clientDataJSON"]))
        return cd["type"] == kind and cd["challenge"] == challenge and cd["origin"] == f"https://{RP_ID}"

    def session(self, name):
        token = os.urandom(16).hex()
        self.server.sessions[token] = name
        return f"rasputin-session={token}"

    def do_GET(self):
        if self.path != "/api/auth/me" or self.server.routes_404:
            return self.reply(404)
        name = self.server.sessions.get(_cookie(self, "rasputin-session") or "")
        if self.server.me_status or not name:
            return self.reply(self.server.me_status or 401, {"error": "auth required"})
        return self.reply(200, {"id": "00", "name": self.server.me_name or name, "displayName": name})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        if self.server.routes_404:
            return self.reply(404)
        if self.path == "/api/auth/register/begin":
            user_id = os.urandom(16)
            token, challenge = self.begin("register", (body["name"], user_id))
            return self.reply(200, {"publicKey": {"challenge": challenge, "rp": {"id": RP_ID, "name": "Rasputin"},
                                                  "user": {"id": b64url(user_id), "name": body["name"]}}},
                              [f"rasputin-pending={token}"])
        if self.path == "/api/auth/register/finish":
            p = self.take("register")
            if not p or not self.client_data_ok(body["response"], "webauthn.create", p[1]):
                return self.reply(400)
            att = _decode(body["response"]["attestationObject"])
            pub = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d030107034200") + b"\x04" + att[-67:-35] + att[-32:]
            self.server.users[p[2][1]] = (p[2][0], pub)
            return self.reply(200, {"name": p[2][0]}, [self.session(p[2][0])])
        if self.path == "/api/auth/login/begin":
            token, challenge = self.begin("login", None)
            return self.reply(200, {"publicKey": {"challenge": challenge, "rpId": RP_ID}}, [f"rasputin-pending={token}"])
        if self.path == "/api/auth/login/finish":
            p = self.take("login")
            if self.server.login_finish_status:
                return self.reply(self.server.login_finish_status, {"error": "refused"})
            r = body["response"]
            user = self.server.users.get(_decode(r["userHandle"]))
            auth = _decode(r["authenticatorData"])
            if not p or not user or not self.client_data_ok(r, "webauthn.get", p[1]) \
                    or auth[:32] != hashlib.sha256(RP_ID.encode()).digest() \
                    or not self.server.verify(user[1], _decode(r["signature"]),
                                              auth + hashlib.sha256(_decode(r["clientDataJSON"])).digest()):
                return self.reply(401, {"error": "auth failed"})
            return self.reply(200, {"name": user[0]}, [self.session(user[0])])
        return self.reply(404)


class LegacyCase(unittest.TestCase):
    def setUp(self):
        self.api = OldApi()
        self.addCleanup(self.api.stop)
        self.state = state_dir(self)
        self.outputs = []

    def legacy(self, verb, ca=None, base=None):
        code, out, err = run([verb, "--name", "smoke-operator", "--base", base or self.api.base, "--state",
                              self.state, "--ca", ca or pki()["ca"], "--timeout", "5"],
                             opener_factory=signin.https_opener)
        self.outputs.append(out + err)
        self.assertRegex(out, LINE)
        return code, out


class LegacyVerbs(LegacyCase):
    """TC-967-05."""

    def test_register_then_sign_in_verified_by_openssl(self):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        code, out = self.legacy("legacy-sign-in")
        self.assertEqual(code, 0, out)
        self.assertEqual(out, "signin legacy-sign-in PASS smoke-operator signed in\n")
        self.assertEqual(self.api.verify_log, ["Verified OK"])

    def refused(self, sentence_part):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        code, out = self.legacy("legacy-sign-in")
        self.assertEqual(code, 1, out)
        self.assertIn("smoke-operator", out)
        self.assertIn(sentence_part, out)

    def test_login_finish_401_fails_naming_the_operator(self):
        self.api.login_finish_status = 401
        self.refused("login/finish (HTTP 401)")

    def test_routes_404_fail(self):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        self.api.routes_404 = True
        code, out = self.legacy("legacy-sign-in")
        self.assertEqual(code, 1, out)
        self.assertIn("smoke-operator", out)
        self.assertIn("HTTP 404", out)

    def test_me_401_after_login_fails(self):
        self.api.me_status = 401
        self.refused("/api/auth/me answered HTTP 401")

    def test_me_naming_another_user_fails(self):
        self.api.me_name = "someone-else"
        self.refused("names another user")

    def test_register_refused_fails(self):
        self.api.routes_404 = True
        code, out = self.legacy("legacy-register")
        self.assertEqual(code, 1)
        self.assertIn("smoke-operator", out)

    def test_no_answer_is_inconclusive(self):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        code, out = self.legacy("legacy-sign-in", base=f"https://127.0.0.1:{closed_port()}")
        self.assertEqual(code, 2, out)

    def test_wrong_ca_is_inconclusive(self):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        code, out = self.legacy("legacy-sign-in", ca=pki()["other"])
        self.assertEqual(code, 2, out)
        self.assertIn("TLS failed", out)

    def test_sign_in_before_register_is_inconclusive(self):
        self.assertEqual(self.legacy("legacy-sign-in")[0], 2)

    # TC-967-04 for the legacy verbs: pass and fail paths print no needle,
    # and the needles hold the session cookie and the key's body.
    def test_tc_967_04_no_needle_in_legacy_output(self):
        self.legacy("legacy-register")
        self.legacy("legacy-sign-in")
        self.api.login_finish_status = 401
        self.legacy("legacy-sign-in")
        with open(os.path.join(self.state, "needles"), encoding="utf-8") as f:
            needles = [n for n in f.read().split("\n") if n]
        self.assertTrue(any(n in self.api.sessions for n in needles), "no session cookie in the needles")
        with open(os.path.join(self.state, "smoke-operator.legacy.key"), encoding="ascii") as f:
            body = [ln.strip() for ln in f if not ln.startswith("-----")]
        self.assertTrue(set(body) <= set(needles))
        self.assertEqual([n for n in needles if n in "".join(self.outputs)], [])


# ------------------------------------------------------------------ TC-967-03


class ExitContract(unittest.TestCase):
    """TC-967-03: every failure path's exit code, and exactly one stdout line."""

    def check(self, result, want):
        code, out, _ = result
        self.assertEqual(code, want, out)
        self.assertRegex(out, LINE)
        self.assertEqual(out.count("\n"), 1)
        return out

    def test_admitted_negative_fails_naming_the_step(self):
        d = state_dir(self)
        st = State(d, os.getuid())
        key = st.key_path("b", "passkey-2fa")
        passkey.OpensslPasskeys().make(key)
        st.save("b", {"label": "b", "username": "b-user", "password": "a-test-password",
                      "passkey_2fa": {"key_path": key, "credential_id": b64url(b"\x01" * 16), "userid": "dXNlcg"}})
        login = (b'<html><body data-page-id="login-login"><form id="kc-form-login" action="https://sso-kc959.local:19591/a" '
                 b'method="post"><input name="username"><input name="password"></form></body></html>')
        authn = (b'<html><body data-page-id="login-webauthn-authenticate"><form id="webauth" '
                 b'action="https://sso-kc959.local:19591/b" method="post"><input name="clientDataJSON"></form>'
                 b'<script>challenge : "AAAA", rpId : "sso-kc959.local",</script></body></html>')
        fake = KeycloakFake()
        fake.script([login, authn])
        out = self.check(run(["negative", "bad-signature", "--state", d, "--doors", write_doors(d), "--ca", "/unused",
                              "--label", "b", "--stock-theme"], fake), 1)
        self.assertIn("bad-signature", out)
        self.assertIn("admitted", out)

    def test_no_http_answer_is_inconclusive(self):
        d = state_dir(self)
        doors = write_doors(d)
        self.check(run(["create-account", "--state", d, "--doors", doors, "--ca", pki()["ca"], "--label", "a",
                        "--connect", f"127.0.0.1:{closed_port()}", "--timeout", "5"],
                       opener_factory=signin.https_opener), 2)

    def test_untrusted_certificate_is_inconclusive(self):
        api = OldApi()
        self.addCleanup(api.stop)
        d = state_dir(self)
        out = self.check(run(["create-account", "--state", d, "--doors", write_doors(d), "--ca", pki()["other"],
                              "--label", "a", "--connect", f"127.0.0.1:{api.server_address[1]}",
                              "--server-name", "127.0.0.1", "--timeout", "5"], opener_factory=signin.https_opener), 2)
        self.assertIn("TLS failed", out)

    def test_openssl_absent_is_inconclusive(self):
        d = state_dir(self)
        empty = tempfile.mkdtemp()
        self.addCleanup(os.rmdir, empty)
        out = self.check(run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS],
                             KeycloakFake(), env={"PATH": empty}), 2)
        self.assertIn("openssl", out)

    def test_bad_arguments_are_inconclusive(self):
        self.check(run(["sign-in", "carrier-pigeon"]), 2)
        self.check(run([]), 2)
        d = state_dir(self)
        self.check(run(["legacy-sign-in", "--state", d, "--ca", "x", "--name", "n", "--base", "https://h",
                        "--connect", "nonsense"]), 2)
        self.check(run(["sign-in", "password", "--state", d, "--ca", "x", "--label", "a", "--doors", "/nonexistent"]), 2)

    def test_empty_page_is_never_a_pass(self):
        fake = KeycloakFake()
        fake.script([b""])
        d = state_dir(self)
        code, out, _ = run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS], fake)
        self.assertIn(code, (1, 2))
        self.assertRegex(out, LINE)

    def test_server_error_is_inconclusive(self):
        d = state_dir(self)
        out = self.check(run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS],
                             lambda *a: (503, [], b"down")), 2)
        self.assertIn("HTTP 503", out)

    def test_unexpected_error_is_inconclusive(self):
        def broken(*a):
            raise RuntimeError("boom")
        d = state_dir(self)
        out = self.check(run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS], broken), 2)
        self.assertIn("RuntimeError", out)


# ------------------------------------------------------------------ TC-967-04


class StateHygiene(unittest.TestCase):
    """TC-967-04: the state directory's mode and owner, and the trap."""

    def test_0755_is_inconclusive(self):
        d = state_dir(self)
        os.chmod(d, 0o755)
        code, out, _ = run(["create-account", "--state", d, "--doors", write_doors(d), *KC_ARGS], KeycloakFake())
        self.assertEqual(code, 2)
        self.assertIn("0755", out)

    def test_another_owner_is_inconclusive(self):
        d = state_dir(self)
        with self.assertRaises(Inconclusive) as caught:
            State(d, os.getuid() + 1)
        self.assertIn("owned by uid", caught.exception.sentence)

    def test_a_file_is_not_a_state_directory(self):
        d = state_dir(self)
        path = os.path.join(d, "f")
        open(path, "w").close()
        with self.assertRaises(Inconclusive):
            State(path, os.getuid())

    def test_logger_redacts_a_needle(self):
        from signin_kit.log import Log
        buf = io.StringIO()
        Log(buf, lambda: {"a-secret-value"}).warn("x", value="a-secret-value", other="two words")
        self.assertEqual(buf.getvalue(), 'level=warn event=x value=[redacted] other="two words"\n')

    def wrapper(self, base):
        """A wrapper with a trap, as the update smoke's cleanup: the state
        directory goes on every exit, a signal included."""
        script = ('d=$(mktemp -d) || exit 2; echo "$d"; '
                  'trap \'rm -rf "$d"\' EXIT; trap \'rm -rf "$d"; kill "$p" 2>/dev/null; exit 143\' INT TERM; '
                  f'"$1" -I "$2" legacy-register --name smoke-operator --base "{base}" --state "$d" --ca "$3" '
                  '--timeout 20 >/dev/null 2>&1 & p=$!; wait "$p"')
        return subprocess.Popen(["sh", "-c", script, "sh", sys.executable, os.path.join(LIB, "signin.py"), pki()["ca"]],
                                stdout=subprocess.PIPE, text=True)

    def test_trap_removes_state_after_a_pass(self):
        api = OldApi()
        self.addCleanup(api.stop)
        proc = self.wrapper(api.base)
        d = proc.stdout.readline().strip()
        proc.stdout.close()
        self.assertEqual(proc.wait(30), 0)
        self.assertEqual(len(api.sessions), 1)
        self.assertFalse(os.path.exists(d))

    def test_trap_removes_state_after_a_killed_run(self):
        hold = socket.socket()
        hold.bind(("127.0.0.1", 0))
        hold.listen(1)
        self.addCleanup(hold.close)
        proc = self.wrapper(f"https://127.0.0.1:{hold.getsockname()[1]}")
        d = proc.stdout.readline().strip()
        proc.stdout.close()
        hold.settimeout(20)
        conn, _ = hold.accept()  # the client is now waiting on its TLS handshake
        self.addCleanup(conn.close)
        self.assertTrue(os.path.isdir(d))
        proc.send_signal(signal.SIGTERM)
        self.assertEqual(proc.wait(30), 143)
        self.assertFalse(os.path.exists(d))


class Units(unittest.TestCase):
    """Edges of the ported modules the flows above do not reach."""

    def test_js_literal_escapes(self):
        self.assertEqual(pages.js_literal('"a\\u0041\\x42\\n\\"q"'), 'aAB\n"q')
        self.assertEqual(pages.js_literal("true"), "true")

    def test_page_helpers_refuse_on_absence(self):
        p = pages.parse('<body data-page-id="login-login"></body>', stock_theme=True)
        for call in (lambda: p.form("x"), lambda: pages.script_args(p, ("rpId",)), lambda: pages.totp_secret(p),
                     lambda: pages.recovery_codes(p), lambda: pages.recovery_code_number(p),
                     lambda: pages.select_options(p)):
            with self.assertRaises(Inconclusive):
                call()
        self.assertEqual(pages.message(p), "")

    def test_mutators_change_one_field(self):
        class Echo:
            def sign(self, m):
                return b"\x30" + bytes(20)
        inputs = passkey.AssertionInputs("rp.test", "https://rp.test", "AAAA", b"\x01", "u")
        good = passkey.build_assertion(inputs, Echo())
        for name in passkey.MUTATORS:
            bad = passkey.mutate(name, inputs, Echo(), {"origin": "https://other.test", "rp_id": "other.test"})
            with self.subTest(name=name):
                self.assertNotEqual((bad.authenticator_data, bad.client_data_json, bad.signature),
                                    (good.authenticator_data, good.client_data_json, good.signature))
        with self.assertRaises(Inconclusive):
            passkey.mutate("nope", inputs, Echo(), {})

    def test_soft_passkey_load_refusals(self):
        with self.assertRaises(Inconclusive):
            passkey.load_soft_passkey("/nonexistent/soft-passkey.py")
        d = state_dir(self)
        bad = os.path.join(d, "bad.py")
        with open(bad, "w") as f:
            f.write("raise ValueError\n")
        with self.assertRaises(Inconclusive):
            passkey.load_soft_passkey(bad)

    def test_redirect_code_refusals(self):
        from signin_kit.transport import Redirect
        with self.assertRaises(FactFailed):
            Redirect("https://c.test/cb?error=access_denied").code()
        with self.assertRaises(FactFailed):
            Redirect("https://c.test/cb#state=x").code()


if __name__ == "__main__":
    # The tests are loaded from this file's own globals, not by unittest.main,
    # which looks up sys.modules["__main__"]: under python3 -m trace that is
    # trace itself, and no test would run.
    _module = type(sys)("signin_test")
    _module.__dict__.update(globals())
    _result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(_module))
    sys.exit(0 if _result.wasSuccessful() and _result.testsRun else 1)
