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
        self.posts = []
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
        # A form's action may be relative, as the door's Keep form's is.
        same_action = [f for f in self.current.forms if urllib.parse.urljoin(url, f.action) == url]
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
            self.posts.append((url, form))
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
BRIDGE_COOKIE = "__Host-rasputin-bridge"


class OldApi(http.server.ThreadingHTTPServer):
    """The pre-identity console's auth routes over TLS, verifying each
    assertion with openssl against the key the registration carried. It also
    serves the move's bridge as rasputin-control-plane e8f75376
    api/internal/auth/bridge.go answers it: the __Host-rasputin-bridge
    cookie, user verification required, a grant under a new cookie value,
    409 has_password for an account that has one, and the coded refusal
    body. `first_passwords` records what the password step set, by name."""

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
        self.first_passwords = {}
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

    def take(self, kind, cookie="rasputin-pending"):
        p = self.server.pending.pop(_cookie(self, cookie) or "", None)
        return p if p and p[0] == kind else None

    def coded(self, status, code):
        """bridge.go's refusal: the coded body, and the cookie cleared."""
        return self.reply(status, {"error": "refused", "code": code, "correlationId": os.urandom(8).hex()},
                          [f"{BRIDGE_COOKIE}=; Max-Age=0"])

    def verified_user(self, r, challenge):
        """The registered user whose key signed this webauthn.get assertion,
        or None."""
        user = self.server.users.get(_decode(r["userHandle"]))
        auth = _decode(r["authenticatorData"])
        if not user or not self.client_data_ok(r, "webauthn.get", challenge) \
                or auth[:32] != hashlib.sha256(RP_ID.encode()).digest() \
                or not self.server.verify(user[1], _decode(r["signature"]),
                                          auth + hashlib.sha256(_decode(r["clientDataJSON"])).digest()):
            return None
        return user, auth[32]

    def bridge(self, body):
        if self.path == "/api/auth/bridge/begin":
            token, challenge = self.begin("bridge", None)
            return self.reply(200, {"publicKey": {"challenge": challenge, "rpId": RP_ID,
                                                  "userVerification": "required"}}, [f"{BRIDGE_COOKIE}={token}"])
        if self.path == "/api/auth/bridge/finish":
            p = self.take("bridge", BRIDGE_COOKIE)
            if not p:
                return self.coded(401, "bridge_expired")
            found = self.verified_user(body["response"], p[1])
            if not found or not found[1] & passkey.FLAG_UV:
                return self.coded(401, "passkey_refused")
            name = found[0][0]
            if name in self.server.first_passwords:
                return self.coded(409, "has_password")
            token = os.urandom(16).hex()
            self.server.pending[token] = ("grant", None, name)
            return self.reply(200, {"next": "/login/bridge"}, [f"{BRIDGE_COOKIE}={token}"])
        if self.path == "/api/auth/bridge/password":
            p = self.take("grant", BRIDGE_COOKIE)
            if not p:
                return self.coded(401, "bridge_expired")
            if not isinstance(body.get("password"), str) or not isinstance(body.get("email"), str):
                return self.coded(400, "invalid_request")
            self.server.first_passwords[p[2]] = (body["password"], body["email"])
            return self.reply(200, {"next": "/api/auth/signin"})
        return self.reply(404)

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
            found = self.verified_user(body["response"], p[1]) if p else None
            if not found:
                return self.reply(401, {"error": "auth failed"})
            return self.reply(200, {"name": found[0][0]}, [self.session(found[0][0])])
        if self.path.startswith("/api/auth/bridge/"):
            return self.bridge(body)
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


class BridgeVerb(LegacyCase):
    """TC-1005-34 (geekdojo/geekdojo-brain#1005): the bridge verb against
    the api fake's bridge routes."""

    PASSWORD = "first-password-for-tc-1005-34"
    EMAIL = "smoke-operator@example.com"

    def bridge(self):
        pwdir = tempfile.mkdtemp(prefix="signin-pw-")
        self.addCleanup(shutil.rmtree, pwdir, True)
        path = os.path.join(pwdir, "pw")
        with open(path, "w", encoding="utf-8") as f:
            f.write(self.PASSWORD + "\n")
        os.chmod(path, 0o600)
        code, out, err = run(["bridge", "--name", "smoke-operator", "--base", self.api.base, "--state", self.state,
                              "--ca", pki()["ca"], "--timeout", "5", "--password-file", path, "--email", self.EMAIL],
                             opener_factory=signin.https_opener)
        self.outputs.append(out + err)
        self.assertRegex(out, LINE)
        return code, out

    # TC-1005-34: the legacy assertion is accepted, the password and email
    # are set, and a second run is refused has_password.
    def test_tc_1005_34_sets_the_first_password_once(self):
        self.assertEqual(self.legacy("legacy-register")[0], 0)
        code, out = self.bridge()
        self.assertEqual(code, 0, out)
        self.assertEqual(out, "signin bridge PASS smoke-operator's pre-update passkey was accepted and its first "
                              "password and email were set\n")
        self.assertEqual(self.api.verify_log, ["Verified OK"])
        self.assertEqual(self.api.first_passwords, {"smoke-operator": (self.PASSWORD, self.EMAIL)})

        code, out = self.bridge()
        self.assertEqual(code, 1, out)
        self.assertIn("/api/auth/bridge/finish (HTTP 409 has_password)", out)
        self.assertEqual(self.api.verify_log, ["Verified OK", "Verified OK"])
        self.assertEqual(self.api.first_passwords, {"smoke-operator": (self.PASSWORD, self.EMAIL)})

        text = "".join(self.outputs)
        self.assertNotIn(self.PASSWORD, text)
        self.assertNotIn(self.EMAIL, text)
        for name in os.listdir(self.state):
            with open(os.path.join(self.state, name), encoding="utf-8", errors="replace") as f:
                self.assertNotIn(self.PASSWORD, f.read(), f"the state file {name} holds the password")


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


# ------------------------------------------------------------------ #1145 set-password

KC = "https://sso-kc959.local:19591/realms/rasputin/login-actions"
LOGIN_PAGE = (f'<html><body data-page-id="login-login" data-rasputin-theme="rasputin">'
              f'<form id="kc-form-login" action="{KC}/authenticate?session_code=s1" method="post">'
              '<input name="username"><input name="password"></form></body></html>').encode()
UPDATE_ACTION = f"{KC}/required-action?session_code=s2&execution=UPDATE_PASSWORD"
UPDATE_PAGE = (f'<html><body data-page-id="login-login-update-password" data-rasputin-theme="rasputin">'
               f'<form id="kc-passwd-update-form" action="{UPDATE_ACTION.replace("&", "&amp;")}" method="post">'
               '<input type="password" name="password-new"><input type="password" name="password-confirm">'
               '<input type="checkbox" name="logout-sessions" value="on" checked></form></body></html>').encode()


def warning_page(fields):
    """The door's warning page as pages.html.tmpl renders it at
    rasputin-control-plane d3fb7170: the Keep form posts to the original
    request URI (relative), carrying every original field and the marker."""
    import html as _html
    keep = "/realms/rasputin/login-actions/required-action?session_code=s2&execution=UPDATE_PASSWORD"
    hidden = "".join(f'<input type="hidden" name="{_html.escape(k)}" value="{_html.escape(v)}">\n'
                     for k, v in sorted(fields.items()))
    return ('<!DOCTYPE html>\n<html class="rasp-signin" lang="en">\n<head><title>Password found in a data breach'
            '</title></head>\n<body class="rasp-body" data-page-id="rasputin-door-warning" '
            'data-rasputin-theme="rasputin">\n<main class="rasp-card">\n'
            '<div id="kc-feedback" class="rasp-alert rasp-alert-error" role="alert"><span class="rasp-alert-text">'
            'This password has appeared in a data breach.</span></div>\n'
            f'<form id="rasputin-keep-form" method="post" action="{_html.escape(keep)}">\n{hidden}'
            '<input type="hidden" name="rasputin-keep-password" value="keep">\n<div class="rasp-buttons">\n'
            '<a class="rasp-btn rasp-btn-block" id="rasputin-choose-another" '
            'href="/realms/rasputin/login-actions/required-action?execution=UPDATE_PASSWORD">Choose a different '
            'password</a>\n<button class="rasp-link" id="rasputin-keep" type="submit">Keep this password</button>\n'
            '</div>\n</form>\n</main>\n</body>\n</html>\n').encode()


class SetPassword(unittest.TestCase):
    """The set-password verb for TC-1145-41's bench run (geekdojo/geekdojo-brain#1145):
    the temporary password reaches UPDATE_PASSWORD, the chosen password is
    posted, and the door's warning is answered with its own Keep form."""

    CHOSEN = "chosen-phrase-for-the-unit-test-1145"
    TEMP = "temporary-admin-set-password"

    def setUp(self):
        self.state = state_dir(self)
        State(self.state, os.getuid()).save("t", {"label": "t", "username": "t-user", "password": self.TEMP})
        self.pwdir = tempfile.mkdtemp(prefix="signin-pw-")
        self.addCleanup(shutil.rmtree, self.pwdir, True)
        self.outputs = []

    def pwfile(self, content, mode=0o600):
        path = os.path.join(self.pwdir, "pw")
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        os.chmod(path, mode)
        return path

    def go(self, fake, path, *extra):
        code, out, err = run(["set-password", "--state", self.state, "--doors", write_doors(), "--ca", "/unused",
                              "--label", "t", "--new-password-file", path, *extra], fake)
        self.outputs.append(out + err)
        self.assertRegex(out, LINE)
        return code, out

    def update_fields(self):
        return {"password-new": self.CHOSEN, "password-confirm": self.CHOSEN, "logout-sessions": "on"}

    def assert_password_absent(self):
        text = "".join(self.outputs)
        self.assertNotIn(self.CHOSEN, text)
        for name in os.listdir(self.state):
            with open(os.path.join(self.state, name), encoding="utf-8", errors="replace") as f:
                self.assertNotIn(self.CHOSEN, f.read(), f"the state file {name} holds the new password")

    def test_warning_then_keep_sets_the_password_and_it_signs_in(self):
        fake = KeycloakFake()
        fake.script([LOGIN_PAGE, UPDATE_PAGE, warning_page(self.update_fields()), None, LOGIN_PAGE])
        code, out = self.go(fake, self.pwfile(self.CHOSEN + "\n"), "--then-sign-in")
        self.assertEqual(code, 0, out)
        self.assertEqual(out, "signin set-password PASS breach warning shown, Keep followed, new password set "
                              f"(length {len(self.CHOSEN)}); the new password signs in; pages=login-login,"
                              "login-login-update-password,rasputin-door-warning,login-login\n")
        self.assertEqual(fake.post_errors, [])
        (login_url, login), (update_url, update), (keep_url, keep), (again_url, again) = fake.posts
        self.assertEqual(login["password"], self.TEMP)
        self.assertEqual(update_url, UPDATE_ACTION)
        self.assertEqual((update["password-new"], update["password-confirm"]), (self.CHOSEN, self.CHOSEN))
        # Keep is the page's own form: its relative action, resolved, and its hidden fields.
        self.assertEqual(keep_url, UPDATE_ACTION)
        self.assertEqual(keep, dict(self.update_fields(), **{"rasputin-keep-password": "keep"}))
        self.assertEqual(again["password"], self.CHOSEN)
        saved = State(self.state, os.getuid()).load("t")
        self.assertEqual(saved["old_password"], self.TEMP)
        self.assertNotIn("password", saved)
        self.assert_password_absent()

    def test_no_warning_is_relayed_and_named(self):
        fake = KeycloakFake()
        fake.script([LOGIN_PAGE, UPDATE_PAGE, None])
        code, out = self.go(fake, self.pwfile(self.CHOSEN))
        self.assertEqual(code, 0, out)
        self.assertEqual(out, "signin set-password PASS no breach warning, relayed, new password set "
                              f"(length {len(self.CHOSEN)}); pages=login-login,login-login-update-password\n")
        self.assertEqual(len(fake.posts), 2)
        self.assertNotIn("rasputin-keep-password", fake.posts[1][1])
        self.assert_password_absent()

    def test_bad_file_mode_is_refused_before_any_call(self):
        fake = KeycloakFake()
        fake.script([LOGIN_PAGE, UPDATE_PAGE, None])
        code, out = self.go(fake, self.pwfile(self.CHOSEN, 0o644))
        self.assertEqual(code, 2, out)
        self.assertIn("mode 0644, not 0600", out)
        self.assertEqual(fake.served, [])
        self.assert_password_absent()

    def test_empty_file_is_refused(self):
        for content in ("", "\n"):
            with self.subTest(content=content):
                code, out = self.go(KeycloakFake(), self.pwfile(content))
                self.assertEqual(code, 2, out)
                self.assertIn("is empty", out)

    def test_failed_update_keeps_the_temporary_password_and_prints_no_password(self):
        refused = UPDATE_PAGE.replace(b"</form>", b'</form><span id="input-error">Invalid password.</span>')
        fake = KeycloakFake()
        fake.script([LOGIN_PAGE, UPDATE_PAGE, refused])
        code, out = self.go(fake, self.pwfile(self.CHOSEN))
        self.assertEqual(code, 1, out)
        self.assertEqual(State(self.state, os.getuid()).load("t")["password"], self.TEMP)
        self.assert_password_absent()


# --------------------------------------------------------- TC-992-38 reset


HOME = "https://sso-kc959.local:19591"
APP = "https://signin.kc959.internal:19591"
CONSOLE_RESET = "https://console.kc959.local/api/auth/reset-done"


def reset_page(page_id, form_id, action, inputs, extra=""):
    fields = "".join(f'<input name="{n}">' for n in inputs)
    return (f'<html><body data-page-id="{page_id}" data-rasputin-theme="rasputin">'
            f'<form id="{form_id}" action="{action}" method="post">{fields}</form>{extra}</body></html>').encode()


class ResetFake:
    """Keycloak and the api for one recovery-code reset, routed by path: the
    sign-in page with its "Forgot your password?" link, choose user, the
    code, an authenticator code when privileged, the new password, the
    reset's return at the console or the app door, the refresh of the old
    token, and the sign-ins after."""

    def __init__(self, origin, privileged=False, session_remains=False, console_says="reset-done"):
        self.origin, self.privileged, self.session_remains, self.console_says = origin, privileged, session_remains, console_says
        kc = f"{origin}/realms/rasputin/login-actions"
        self.login = reset_page("login-login", "kc-form-login", f"{kc}/authenticate?session_code=s1",
                                ["username", "password"],
                                f'<a id="rasputin-forgot-password" href="{kc}/reset-credentials?client_id=r&amp;redirect_uri=x">'
                                "Forgot your password?</a>")
        self.choose = reset_page("login-login-reset-password", "kc-reset-password-form", f"{kc}/reset-credentials?s=2", ["username"])
        self.code = reset_page("login-login-recovery-authn-code-input", "kc-recovery-code-login-form", f"{kc}/reset-credentials?s=3",
                               ["recoveryCodeInput"], "<label for=\"recoveryCodeInput\">Recovery code #2</label>")
        self.otp = reset_page("login-login-otp", "kc-otp-login-form", f"{kc}/reset-credentials?s=4", ["otp"])
        self.update = reset_page("login-login-update-password", "kc-passwd-update-form", f"{kc}/reset-credentials?s=5",
                                 ["password-new", "password-confirm"])
        self.info = (b'<html><body class="rasp-body" data-page-id="rasputin-door-info" data-rasputin-theme="rasputin">'
                     b'<p>Your password is changed. Sign in with it and your second step.</p></body></html>')
        self.posts, self.pending, self.new_password, self.delivered = [], None, None, []

    def __call__(self, method, url, headers, body):
        split = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(split.query))
        form = dict(urllib.parse.parse_qsl(body.decode(), keep_blank_values=True)) if body else {}
        if method == "POST":
            self.posts.append((split.path + ("?" + split.query if split.query else ""), form))
        path = split.path
        if path.endswith("/protocol/openid-connect/auth"):
            self.pending = {"redirect_uri": query["redirect_uri"], "state": query["state"], "challenge": query["code_challenge"]}
            return 200, [], self.login
        if path.endswith("/protocol/openid-connect/token"):
            if form.get("grant_type") == "refresh_token":
                if self.session_remains:
                    return 200, [], json.dumps({"access_token": "a"}).encode()
                return 400, [], json.dumps({"error": "invalid_grant"}).encode()
            if pkce.challenge(form.get("code_verifier", "")) != self.pending["challenge"]:
                return 400, [], json.dumps({"error": "invalid_grant"}).encode()
            claims = b64url(json.dumps({"sub": "user-1"}).encode())
            return 200, [], json.dumps({"access_token": "at-new", "refresh_token": "rt-new",
                                        "id_token": f"eyJhbGciOiJub25lIn0.{claims}.sig-new"}).encode()
        if path.endswith("/authenticate"):
            if self.privileged and form.get("password") == self.new_password:
                kc = f"{self.origin}/realms/rasputin/login-actions"
                return 200, [], reset_page("login-login-otp", "kc-otp-login-form", f"{kc}/authenticate?otp=1", ["otp"])
            if form.get("password") == self.new_password or "otp" in form:
                return 302, [("Location", self.pending["redirect_uri"] + "?" + urllib.parse.urlencode(
                    {"code": "code-new", "state": self.pending["state"]}))], b""
            return 200, [], self.login
        if path.endswith("/reset-credentials") and method == "GET":
            return 200, [], self.choose
        if path.endswith("/reset-credentials"):
            step = query.get("s")
            if step == "2":
                return 200, [], self.code
            if step == "3":
                return 200, [], self.otp if self.privileged else self.update
            if step == "4":
                return 200, [], self.update
            self.new_password = form.get("password-new")
            done = (CONSOLE_RESET if self.origin == HOME else f"{APP}/api/auth/reset-done") + "?code=reset-code&iss=x"
            return 302, [("Location", done)], b""
        if path == "/api/auth/reset-done":
            self.delivered.append(url)
            if split.netloc.startswith("console."):
                return 303, [("Location", f"/login?signin={self.console_says}")], b""
            return 200, [], self.info
        return 404, [], b"not found"


class ResetPasswordRecoveryCode(unittest.TestCase):
    """TC-992-38: `signin.py reset-password recovery-code` parses and runs
    choose user, the code, the privileged step if any, the new password and
    the reset's return; it fails naming the fact when a session remains or
    the old password still works."""

    OLD = "old-password-for-the-reset-992"

    def setUp(self):
        self.state = state_dir(self)
        State(self.state, os.getuid()).save("r", {
            "label": "r", "username": "r-user", "password": self.OLD, "user_id": "user-1",
            "recovery_codes": ["code-one-0001", "code-two-0002"], "totp_secret": "",
            "tokens": {"refresh_token": "rt-old"}})

    def go(self, fake, door="home"):
        code, out, err = run(["reset-password", "recovery-code", "--state", self.state, "--doors", write_doors(),
                              "--ca", "/unused", "--label", "r", "--door", door], fake)
        self.assertRegex(out, LINE)
        self.assertNotIn(self.OLD, out + err)
        return code, out

    def test_home_door_reset_delivers_the_return_and_checks_the_old_password(self):
        fake = ResetFake(HOME)
        code, out = self.go(fake)
        self.assertEqual(code, 0, out)
        self.assertEqual(out, "signin reset-password PASS the console answered reset-done; pages=login-login,"
                              "login-login-reset-password,login-login-recovery-authn-code-input,"
                              "login-login-update-password,login-login,login-login,login-login\n")
        paths = [p for p, _ in fake.posts]
        self.assertEqual(fake.posts[0][1], {"username": "r-user"})
        self.assertEqual(fake.posts[1][1], {"recoveryCodeInput": "code-two-0002"})
        self.assertEqual(fake.delivered, [CONSOLE_RESET + "?code=reset-code&iss=x"])
        self.assertIn(("/realms/rasputin/protocol/openid-connect/token",
                       {"grant_type": "refresh_token", "refresh_token": "rt-old", "client_id": "rasputin-console"}), fake.posts)
        self.assertTrue(any(f.get("password") == self.OLD for _, f in fake.posts), paths)
        saved = State(self.state, os.getuid()).load("r")
        self.assertEqual(saved["old_password"], self.OLD)
        self.assertEqual(saved["password"], fake.new_password)

    def test_app_door_reads_its_page_and_a_privileged_reset_gives_its_code(self):
        state = State(self.state, os.getuid())
        account = state.load("r")
        account["totp_secret"] = base64.b32encode(b"0123456789abcdef0123").decode()
        state.save("r", account)
        fake = ResetFake(APP, privileged=True)
        code, out = self.go(fake, door="app")
        self.assertEqual(code, 0, out)
        self.assertIn("PASS the app door said the password is changed;", out)
        self.assertIn("login-login-otp", out)
        self.assertTrue(any("otp" in f for _, f in fake.posts))
        self.assertFalse(any("recoveryCodeInput" in f for _, f in fake.posts[2:]), "a second recovery code was given")

    def test_a_session_that_remains_fails_naming_it(self):
        code, out = self.go(ResetFake(HOME, session_remains=True))
        self.assertEqual(code, 1, out)
        self.assertIn("A session remains after the reset", out)

    def test_the_console_saying_anything_else_fails(self):
        code, out = self.go(ResetFake(HOME, console_says="reset-incomplete"))
        self.assertEqual(code, 1, out)
        self.assertIn("reset-incomplete, not reset-done", out)

    def test_the_old_password_still_working_fails_naming_it(self):
        fake = ResetFake(HOME)
        real = fake.__call__

        def old_works(method, url, headers, body):
            if body and b"password=" + self.OLD.encode() in body:
                fake.new_password = self.OLD
            return real(method, url, headers, body)
        code, out = self.go(old_works)
        self.assertEqual(code, 1, out)
        self.assertIn("The old password was not refused after the reset", out)

    def test_no_codes_is_inconclusive_and_the_choice_parses(self):
        state = State(self.state, os.getuid())
        account = state.load("r")
        account["recovery_codes"] = []
        state.save("r", account)
        code, out = self.go(ResetFake(HOME))
        self.assertEqual(code, 2, out)
        self.assertIn("holds no recovery codes", out)
        code, out, _ = run(["reset-password", "email", "--state", self.state, "--doors", write_doors(),
                            "--ca", "/unused", "--label", "r"], ResetFake(HOME))
        self.assertEqual(code, 2, out)

# ------------------------------------------------- #993 the console's path

CONSOLE = "https://c993.local"
DOOR993 = "https://sso-c993.local"
KC993 = f"{DOOR993}/realms/rasputin/login-actions"
RP993 = "sso-c993.local"
METHODS993 = {"totp": "authenticator_app", "passkey": "passkey", "passkey-2fa": "security_key",
              "recovery-codes": "recovery_codes"}
KC_FOR = {"add_authenticator_app": "CONFIGURE_TOTP", "add_passkey": "webauthn-register-passwordless",
          "add_security_key": "webauthn-register", "add_recovery_codes": "CONFIGURE_RECOVERY_AUTHN_CODES"}
SESSION993 = "__Host-rasputin-session"
PENDING993 = "__Host-rasputin-pending"
CLOCK_SENTENCE = ("Authenticator apps can be added once Rasputin's clock is set. Add a passkey or security key "
                  "now, or try again later.")


def console_doors(console="default", home_extra=None):
    """A doors file whose home door is the console's (#993); the app door is
    named for the negatives' other origin and RP ID only."""
    CLEANUP.append(tempfile.mkdtemp(prefix="signin-doors-"))
    path = os.path.join(CLEANUP[-1], "doors.json")
    home = {"origin": DOOR993, "realm": "rasputin", "client_id": "rasputin-console",
            "redirect_uri": CONSOLE + "/api/auth/callback"}
    if console == "default":
        home["console"] = {"origin": CONSOLE, "methods_route": "/api/me/sign-in-methods", "methods": METHODS993}
    elif console is not None:
        home["console"] = console
    home.update(home_extra or {})
    app = {"origin": "https://signin.c993.internal", "realm": "rasputin", "client_id": "no-app-client",
           "redirect_uri": "https://app.c993.internal/callback"}
    with open(path, "w", encoding="utf-8") as f:
        json.dump({"home": home, "app": app}, f)
    return path


def tpage(page_id, forms=(), extra="", theme=True):
    """A themed door page: forms are (form id, {input: value})."""
    body = f'<html><body data-page-id="{page_id}"' + (' data-rasputin-theme="rasputin"' if theme else "") + ">"
    for fid, fields in forms:
        inputs = "".join(f'<input type="hidden" name="{n}" value="{v}">' for n, v in fields.items())
        body += f'<form id="{fid}" action="{KC993}/authenticate?f={fid}" method="post">{inputs}</form>'
    return (body + extra + "</body></html>").encode()


WEBAUTH_FIELDS = {n: "" for n in ("clientDataJSON", "authenticatorData", "signature", "credentialId", "userHandle", "error")}
P993 = {
    "register": tpage("login-register", [("kc-register-form", {"username": "", "email": "", "password": "",
                                                               "password-confirm": ""})]),
    "codes": tpage("login-login-recovery-authn-code-config", [("kc-recovery-codes-settings-form", {
        "generatedRecoveryAuthnCodes": "rc-aaaa-0001,rc-bbbb-0002,rc-cccc-0003", "generatedAt": "1"})]),
    # The theme's sign-in page: WebAuthn arguments as data- attributes.
    "login": tpage("login-login", [("kc-form-login", {"username": "", "password": ""}), ("webauth", WEBAUTH_FIELDS)],
                   f'<button id="authenticateWebAuthnButton" data-challenge="Y2hhbGxlbmdlLTk5Mw" '
                   f'data-rp-id="{RP993}">Use a passkey</button>'),
    "otp": tpage("login-login-otp", [("kc-otp-login-form", {"otp": ""})]),
    "config-totp": tpage("login-login-config-totp", [("kc-totp-settings-form", {
        "totp": "", "userLabel": "", "totpSecret": os.urandom(10).hex()})]),
    "register-passkey": tpage("login-webauthn-register", [("register", {
        n: "" for n in ("clientDataJSON", "attestationObject", "publicKeyCredentialId", "authenticatorLabel",
                        "transports", "authenticatorAttachment", "error")})],
        f'<div id="rasputin-passkey" data-challenge="VzVgrW-dTEig7tCOC9EwFQ" data-userid="dXNlcg" '
        f'data-rp-id="{RP993}"></div>'),
    "webauthn-error": tpage("login-webauthn-error"),
    "error": tpage("login-error"),
    "not-ready": tpage("rasputin-door-not-ready"),
    "refusal": tpage("rasputin-door-refusal", extra='<p class="kc-feedback-text">This sign-in step wasn&#39;t '
                                                    'started by Rasputin, so it was refused.</p>'),
}


class ConsoleFake:
    """The console at c993.local (its start, #1150's launcher, its callback,
    /me and logout) and the home door at sso-c993.local, whose pages are
    scripted: each authorization request and form post takes the next body,
    and once they are spent, or at a None, the door redirects to the
    console's callback with a code."""

    def __init__(self):
        self.queue, self.requests, self.auths, self.posts = [], [], [], []
        self.launch_bodies, self.action_gets, self.callbacks, self.logouts = [], [], [], []
        self.sessions, self.ended = {}, set()
        self.counter, self.me_calls = 0, 0
        self.username, self.state, self.in_action, self.pending_action = None, None, False, None
        self.roles = []
        # Knobs for the refusals.
        self.start_refusal = self.callback_key = self.launch = self.me_status = self.me_name = None
        self.no_session = self.action_sets_session = self.grant_on_action = False
        self.action_status = "success"
        self.end_on_logout = True

    def script(self, bodies):
        self.queue = list(bodies)

    @staticmethod
    def jar_of(headers):
        out = {}
        for part in (headers.get("Cookie") or "").split(";"):
            if "=" in part:
                k, v = part.strip().split("=", 1)
                out[k] = v
        return out

    def _door_page(self):
        if self.queue and self.queue[0] is not None:
            body = self.queue.pop(0)
            refused = b"rasputin-door-refusal" in body or b'"login-error"' in body
            self.counter += 1
            return (400 if refused else 200), [
                ("Set-Cookie", f"KC_RESTART=restart-{self.counter:08d}; Path=/realms/rasputin/; Secure")], body
        if self.queue:
            self.queue.pop(0)
        self.counter += 1
        q = {"code": f"code-{self.counter:08d}-{os.urandom(4).hex()}", "state": self.state,
             "iss": DOOR993 + "/realms/rasputin"}
        if self.in_action:
            q["kc_action_status"] = self.action_status
        return 302, [("Location", CONSOLE + "/api/auth/callback?" + urllib.parse.urlencode(q))], b""

    def _to_door(self, prompt, kc_action=None, set_pending=True):
        self.counter += 1
        self.state = f"console-state-{self.counter}"
        q = {"client_id": "rasputin-console", "redirect_uri": CONSOLE + "/api/auth/callback",
             "response_type": "code", "scope": "openid", "state": self.state, "code_challenge": "held-by-the-api",
             "code_challenge_method": "S256", "prompt": prompt}
        if kc_action:
            q["kc_action"] = kc_action
        headers = [("Location", f"{DOOR993}/realms/rasputin/protocol/openid-connect/auth?" + urllib.parse.urlencode(q))]
        if set_pending:
            headers.append(("Set-Cookie", f"{PENDING993}=pending-{self.counter:08d}; Path=/; Secure; HttpOnly"))
        return 303, headers, b""

    def __call__(self, method, url, headers, body):
        split = urllib.parse.urlsplit(url)
        q = dict(urllib.parse.parse_qsl(split.query))
        cookies = self.jar_of(headers)
        self.requests.append((method, split.hostname, split.path, q, cookies))
        if split.hostname == "c993.local":
            return self._console(method, split.path, q, cookies, body)
        if split.hostname != "sso-c993.local":
            return 404, [], b"not found"
        if split.path.endswith("/protocol/openid-connect/auth"):
            self.auths.append(q)
            return self._door_page()
        if method == "POST":
            form = dict(urllib.parse.parse_qsl(body.decode(), keep_blank_values=True))
            if form.get("username"):
                self.username = form["username"]
            self.posts.append(form)
            return self._door_page()
        return 404, [], b"not found"

    def _console(self, method, path, q, cookies, body):
        def launcher(key=None):
            return 303, [("Location", "/login" + (f"?signin={key}" if key else ""))], b""
        session = cookies.get(SESSION993)
        live = session in self.sessions and session not in self.ended
        if method == "GET" and path in ("/api/auth/signin", "/api/auth/signup") and "action" not in q:
            if self.start_refusal:
                return launcher(self.start_refusal)
            self.in_action = False
            return self._to_door("create" if path.endswith("signup") else "login")
        if method == "POST" and path == "/api/me/sign-in-methods":
            self.launch_bodies.append((json.loads(body), headers_ct(body)))
            if not live:
                return 401, [], b'{"error":"auth required"}'
            if self.launch:
                return self.launch[0], [], json.dumps(self.launch[1]).encode()
            self.pending_action = "add_" + json.loads(body)["method"]
            self.counter += 1
            return 200, [("Set-Cookie", f"{PENDING993}=prepared-{self.counter:08d}; Path=/; Secure; HttpOnly")], \
                json.dumps({"next": f"/api/auth/signin?action={self.pending_action}"}).encode()
        if method == "GET" and path == "/api/auth/signin":
            self.action_gets.append((q["action"], cookies.get(PENDING993, "")))
            if not live or not cookies.get(PENDING993, "").startswith("prepared-") or q["action"] != self.pending_action:
                return launcher("action-failed")
            self.in_action = True
            return self._to_door("login", KC_FOR[q["action"]], set_pending=False)
        if path == "/api/auth/callback":
            self.callbacks.append((q, cookies.get(PENDING993, "")))
            if self.callback_key:
                return launcher(self.callback_key)
            headers = [("Location", "/login"), ("Set-Cookie", f"{PENDING993}=; Path=/; Max-Age=0; Secure")]
            if self.in_action and self.grant_on_action:
                self.ended |= set(self.sessions)
            if (not self.in_action and not self.no_session) or (self.in_action and self.action_sets_session):
                self.counter += 1
                value = f"session-{self.counter:08d}-{os.urandom(6).hex()}"
                self.sessions[value] = self.username
                headers.append(("Set-Cookie", f"{SESSION993}={value}; Path=/; Secure; HttpOnly; SameSite=Lax"))
            return 303, headers, b""
        if path == "/api/auth/me":
            self.me_calls += 1
            if self.me_status:
                return self.me_status, [], b'{"error":"x"}'
            if not live:
                return 401, [], b'{"error":"auth required"}'
            return 200, [], json.dumps({"sub": "u-1", "name": self.me_name or self.sessions[session],
                                        "roles": self.roles, "capabilities": []}).encode()
        if method == "POST" and path == "/api/auth/logout":
            self.logouts.append(session)
            if self.end_on_logout and session:
                self.ended.add(session)
            return 200, [("Set-Cookie", f"{SESSION993}=; Path=/; Max-Age=0; Secure")], b'{"status":"ok"}'
        return 404, [], b"not found"


def headers_ct(body):
    return "json" if body and body.startswith(b"{") else "none"


class ConsolePath(unittest.TestCase):
    """geekdojo/geekdojo-brain#993: the console's start, callback, /me,
    #1150's launcher, sign-out, --jar and door-page, on the scripted fake."""

    def setUp(self):
        self.state = state_dir(self)
        self.doors = console_doors()
        self.fake = ConsoleFake()
        self.clock = FixedClock()
        self.outputs = []

    def go(self, *verb, label="o", doors=None, fake=None, extra=()):
        code, out, err = run([*verb, "--state", self.state, "--doors", doors or self.doors, "--ca", "/unused",
                              "--label", label, *extra], fake or self.fake, clock=self.clock)
        self.outputs.append(out + err)
        self.assertRegex(out, LINE)
        self.assertEqual(out.count("\n"), 1)
        return code, out

    def create(self):
        self.fake.script([P993["register"], P993["codes"], None])
        code, out = self.go("create-account")
        self.assertEqual(code, 0, out)
        return out

    def account(self, label="o"):
        return State(self.state, os.getuid()).load(label)

    # TC-993-01: the start is the console's, followed to the door.
    def test_tc_993_01_create_and_sign_in_start_at_the_console(self):
        self.create()
        first = self.fake.requests[0]
        self.assertEqual(first[:3], ("GET", "c993.local", "/api/auth/signup"))
        self.assertEqual(self.fake.auths[0]["prompt"], "create")
        self.fake.script([P993["login"], None])
        code, out = self.go("sign-in", "password")
        self.assertEqual(code, 0, out)
        starts = [r[:3] for r in self.fake.requests if r[1] == "c993.local" and r[2].startswith("/api/auth/sign")]
        self.assertEqual(starts, [("GET", "c993.local", "/api/auth/signup"), ("GET", "c993.local", "/api/auth/signin")])
        self.assertEqual(self.fake.auths[1]["prompt"], "login")
        # Every authorization request is the console's own: its state, its
        # challenge; the client built none and called no token endpoint.
        for auth in self.fake.auths:
            self.assertTrue(auth["state"].startswith("console-state-"), auth)
            self.assertEqual(auth["code_challenge"], "held-by-the-api")
        self.assertFalse([r for r in self.fake.requests if r[2].endswith("/token")])

    def test_tc_993_01_a_console_refusal_at_the_start_fails_naming_its_key(self):
        for key in ("unavailable", "wrong-host"):
            with self.subTest(key=key):
                self.fake.start_refusal = key
                code, out = self.go("create-account")
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL fact=console start:", out)
                self.assertIn(f"signin={key}", out)

    # TC-993-02: the callback, the session and /me's roles.
    def test_tc_993_02_the_callback_mints_a_session_and_me_names_the_roles(self):
        out = self.create()
        self.assertIn("roles=none;", out)
        self.assertIn("pages=login-register,login-login-recovery-authn-code-config", out)
        query, pending = self.fake.callbacks[0]
        self.assertTrue(query["code"].startswith("code-"))
        self.assertTrue(pending.startswith("pending-"), "the callback was not delivered with the pending cookie")
        self.fake.roles = ["admin"]
        self.fake.script([P993["login"], None])
        code, out = self.go("sign-in", "password")
        self.assertEqual(code, 0, out)
        self.assertIn("signin sign-in PASS roles=admin;", out)
        account = self.account()
        self.assertIn(account["console_session"], self.fake.sessions)
        self.assertEqual(account["roles"], ["admin"])
        self.assertEqual(account["recovery_codes"], ["rc-aaaa-0001", "rc-bbbb-0002", "rc-cccc-0003"])

    # TC-993-03: each refusal at the callback or /me is its own failed fact.
    def test_tc_993_03_a_callback_refusal_fails_naming_the_key(self):
        for key in ("failed", "expired", "action-failed"):
            with self.subTest(key=key):
                self.fake.callback_key = key
                self.fake.script([P993["register"], P993["codes"], None])
                code, out = self.go("create-account")
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL fact=console callback:", out)
                self.assertIn(f"signin={key}", out)

    def test_tc_993_03_no_session_cookie_fails(self):
        self.fake.no_session = True
        self.fake.script([P993["register"], P993["codes"], None])
        code, out = self.go("create-account")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL fact=session:", out)

    def test_tc_993_03_me_refusing_or_naming_another_fails(self):
        for status in (401, 500):
            with self.subTest(status=status):
                self.fake.me_status = status
                self.fake.script([P993["register"], P993["codes"], None])
                code, out = self.go("create-account")
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL fact=me:", out)
                self.assertIn(f"HTTP {status}", out)
        self.fake.me_status, self.fake.me_name = None, "someone-else"
        self.fake.script([P993["register"], P993["codes"], None])
        code, out = self.go("create-account")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL fact=me: GET /api/auth/me named another account.", out)

    def test_tc_993_03_an_action_status_other_than_success_fails(self):
        self.create()
        for status in ("error", "cancelled"):
            with self.subTest(status=status):
                self.fake.action_status = status
                self.fake.script([P993["login"], None, P993["login"], P993["codes"], None])
                code, out = self.go("enrol", "recovery-codes")
                self.assertEqual(code, 1, out)
                self.assertIn("FAIL fact=kc_action_status:", out)
                self.assertIn(status, out)

    # TC-993-04: enrolment through #1150's launcher.
    def test_tc_993_04_each_kind_posts_its_method_and_follows_next(self):
        self.create()
        action_page = {"totp": "config-totp", "passkey": "register-passkey", "passkey-2fa": "register-passkey",
                       "recovery-codes": "codes"}
        for kind in ("recovery-codes", "passkey-2fa", "passkey", "totp"):
            with self.subTest(kind=kind):
                second = [P993["otp"]] if self.account().get("totp_secret") else []
                self.fake.script([P993["login"], *second, None, P993["login"], *second, P993[action_page[kind]], None])
                before = len(self.fake.posts)
                code, out = self.go("enrol", kind)
                self.assertEqual(code, 0, out)
                body, kind_of_body = self.fake.launch_bodies[-1]
                self.assertEqual(body, {"method": METHODS993[kind]})
                self.assertEqual(kind_of_body, "json")
                action, pending = self.fake.action_gets[-1]
                self.assertEqual(action, "add_" + METHODS993[kind])
                self.assertTrue(pending.startswith("prepared-"), "next was not GET with the launcher's pending cookie")
                # A fresh sign-in at the door precedes the action's page.
                self.assertEqual(self.fake.auths[-1]["prompt"], "login")
                self.assertEqual(self.fake.auths[-1]["kc_action"], KC_FOR[action])
                posted = self.fake.posts[before:]
                self.assertEqual(sum(1 for f in posted if "password" in f), 2, "two password steps")
        # The account holds the code last: its fresh sign-in answered it too.
        self.fake.script([P993["login"], P993["otp"], None, P993["login"], P993["otp"], P993["codes"], None])
        code, out = self.go("enrol", "recovery-codes")
        self.assertEqual(code, 0, out)
        self.assertIn("pages=login-login,login-login-otp,login-login,login-login-otp,"
                      "login-login-recovery-authn-code-config", out)

    def test_tc_993_04_launcher_refusals(self):
        self.create()
        cases = [((409, {"error": CLOCK_SENTENCE, "code": "clock_not_set"}), 1, "FAIL fact=clock:"),
                 ((400, {"error": "Choose a passkey, a security key, an authenticator app or recovery codes."}), 1,
                  "FAIL fact=enrol start:"),
                 ((401, {"error": "auth required"}), 1, "FAIL fact=enrol start:"),
                 ((404, {}), 1, "FAIL fact=enrol start:"),
                 ((200, {}), 2, "INCONCLUSIVE"),
                 ((200, {"next": "/api/auth/signin?elsewhere=1"}), 2, "INCONCLUSIVE")]
        for launch, want, says in cases:
            with self.subTest(launch=launch):
                self.fake.launch = launch
                self.fake.script([P993["login"], None])
                code, out = self.go("enrol", "totp")
                self.assertEqual(code, want, out)
                self.assertIn(says, out)
                if launch[0] == 409:
                    self.assertIn(CLOCK_SENTENCE, out)

    def test_tc_993_04_the_door_refusing_the_forwarded_action_fails(self):
        self.create()
        self.fake.script([P993["login"], None, P993["refusal"]])
        code, out = self.go("enrol", "totp")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL fact=kc_action:", out)
        self.assertIn("rasputin-door-refusal", out)

    # TC-993-05: an action's return mints no session and is not read with /me.
    def test_tc_993_05_the_grant_ending_sessions_does_not_fail_the_enrol(self):
        self.create()
        self.fake.grant_on_action = True
        self.fake.script([P993["login"], None, P993["login"], P993["config-totp"], None])
        me_before = self.fake.me_calls
        code, out = self.go("enrol", "totp")
        self.assertEqual(code, 0, out)
        # /me ran once, for the console sign-in before the launcher, and the
        # session that sign-in minted is now ended: /me would answer 401.
        self.assertEqual(self.fake.me_calls, me_before + 1)
        self.assertIn(self.account()["console_session"], self.fake.ended)
        self.assertTrue(self.account()["totp_secret"])

    def test_tc_993_05_an_action_return_that_sets_a_session_fails(self):
        self.create()
        self.fake.action_sets_session = True
        self.fake.script([P993["login"], None, P993["login"], P993["codes"], None])
        code, out = self.go("enrol", "recovery-codes")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL fact=action return:", out)

    # TC-993-06: sign-out.
    def test_tc_993_06_sign_out_posts_logout_and_me_then_answers_401(self):
        self.create()
        session = self.account()["console_session"]
        code, out = self.go("sign-out")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.fake.logouts, [session])
        me = [r for r in self.fake.requests if r[2] == "/api/auth/me"][-1]
        self.assertEqual(me[4].get(SESSION993), session, "/me after sign-out did not carry the signed-out session")
        self.assertNotIn("console_session", self.account())

    def test_tc_993_06_a_session_that_survives_logout_fails(self):
        self.create()
        self.fake.end_on_logout = False
        code, out = self.go("sign-out")
        self.assertEqual(code, 1, out)
        self.assertIn("FAIL fact=signed out:", out)

    def test_tc_993_06_no_saved_session_is_inconclusive(self):
        State(self.state, os.getuid()).save("o", {"label": "o", "username": "o-user", "password": "pw-pw-pw-pw"})
        code, out = self.go("sign-out")
        self.assertEqual(code, 2, out)
        self.assertIn("holds no console session", out)

    # TC-993-07: --jar.
    def test_tc_993_07_the_jar_is_0600_and_holds_only_the_console_cookies(self):
        jar = os.path.join(state_dir(self), "smoke.jar")
        self.create()
        self.fake.script([P993["login"], None])
        code, out = self.go("sign-in", "password", extra=("--jar", jar))
        self.assertEqual(code, 0, out)
        self.assertEqual(stat.S_IMODE(os.stat(jar).st_mode), 0o600)
        with open(jar, encoding="utf-8") as f:
            lines = f.read().splitlines()
        self.assertEqual(lines[0], "# Netscape HTTP Cookie File")
        rows = [ln.split("\t") for ln in lines[1:]]
        self.assertTrue(rows)
        self.assertEqual({r[0].removeprefix("#HttpOnly_") for r in rows}, {"c993.local"})
        self.assertIn(SESSION993, [r[5] for r in rows])
        session = [r for r in rows if r[5] == SESSION993][0]
        self.assertEqual((session[1], session[2], session[3], session[6]),
                         ("FALSE", "/", "TRUE", self.account()["console_session"]))
        self.assertTrue(session[0].startswith("#HttpOnly_"))

    def test_tc_993_07_an_existing_file_or_link_is_refused_and_left_alone(self):
        d = state_dir(self)
        self.create()
        existing = os.path.join(d, "existing.jar")
        with open(existing, "w") as f:
            f.write("keep me\n")
        target = os.path.join(d, "target")
        with open(target, "w") as f:
            f.write("target\n")
        link = os.path.join(d, "link.jar")
        os.symlink(target, link)
        for path in (existing, link):
            with self.subTest(path=os.path.basename(path)):
                served = len(self.fake.requests)
                code, out = self.go("sign-in", "password", extra=("--jar", path))
                self.assertEqual(code, 2, out)
                self.assertIn("already exists", out)
                self.assertEqual(len(self.fake.requests), served, "the verb ran before the jar was refused")
        with open(existing) as f:
            self.assertEqual(f.read(), "keep me\n")
        with open(target) as f:
            self.assertEqual(f.read(), "target\n")
        self.fake.script([P993["login"], None])
        code, out = self.go("sign-in", "password", extra=("--jar", os.path.join(d, "no-such-dir", "j")))
        self.assertEqual(code, 2, out)
        self.assertIn("could not be written", out)

    # TC-993-08: no secret in any output.
    def test_tc_993_08_no_cookie_password_code_or_secret_is_printed(self):
        d = state_dir(self)
        self.create()
        self.fake.script([P993["login"], None, P993["login"], P993["config-totp"], None])
        self.go("enrol", "totp", extra=("--jar", os.path.join(d, "j1")))
        self.go("enrol", "totp", extra=("--jar", os.path.join(d, "j1")))  # the jar refusal
        self.fake.callback_key = "failed"
        self.fake.script([P993["login"], P993["otp"]])
        self.go("sign-in", "password-totp")
        self.fake.callback_key = None
        self.go("sign-out")
        account = self.account()
        secrets = [account["password"], account["totp_secret"], *account["recovery_codes"],
                   *self.fake.sessions, *[q["code"] for q, _ in self.fake.callbacks]]
        with open(os.path.join(self.state, "needles"), encoding="utf-8") as f:
            needles = [n for n in f.read().split("\n") if n]
        for s in secrets:
            self.assertIn(s, needles)
        text = "".join(self.outputs)
        self.assertEqual([n for n in needles + secrets if n in text], [])

    # TC-993-09: the RP ID in the fact line.
    def test_tc_993_09_passkey_enrol_and_sign_in_name_the_rp_id(self):
        self.create()
        self.fake.script([P993["login"], None, P993["login"], P993["register-passkey"], None])
        code, out = self.go("enrol", "passkey")
        self.assertEqual(code, 0, out)
        self.assertIn(f"rp_id={RP993};", out)
        self.fake.script([P993["login"], None])
        code, out = self.go("sign-in", "passkey")
        self.assertEqual(code, 0, out)
        self.assertIn(f"rp_id={RP993};", out)
        posted = self.fake.posts[-1]
        client = json.loads(passkey.b64url_decode(posted["clientDataJSON"]))
        self.assertEqual((client["challenge"], client["origin"]), ("Y2hhbGxlbmdlLTk5Mw", DOOR993))
        self.assertEqual(passkey.b64url_decode(posted["authenticatorData"])[:32],
                         hashlib.sha256(RP993.encode()).digest())

    # TC-993-10: admin-password-alone on the real flow.
    def test_tc_993_10_admin_password_alone(self):
        self.create()
        cases = [([P993["login"], P993["otp"]], 0, "refused: the page login-login-otp;"),
                 ([P993["login"], None], 1, "admitted"),
                 ([P993["login"], P993["error"]], 1, "the page login-error")]
        for script, want, says in cases:
            with self.subTest(says=says):
                self.fake.script(script)
                code, out = self.go("negative", "admin-password-alone")
                self.assertEqual(code, want, out)
                self.assertIn(says, out)

    # TC-993-11: door-page passes only on the themed registration form.
    def test_tc_993_11_door_page(self):
        cases = [([P993["register"]], 0), ([P993["error"]], 2), ([P993["not-ready"]], 2),
                 ([tpage("login-made-up")], 2), ([tpage("login-register", theme=False)], 2)]
        for script, want in cases:
            with self.subTest(page=script[0][:60]):
                self.fake.script(script)
                code, out = self.go("door-page")
                self.assertEqual(code, want, out)
        self.fake.start_refusal = "unavailable"
        code, out = self.go("door-page")
        self.assertEqual(code, 2, out)
        self.assertIn("signin=unavailable", out)

        def no_answer(*a):
            raise Inconclusive("GET https://c993.local/api/auth/signup gave no HTTP answer (OSError).")
        code, out = self.go("door-page", fake=no_answer)
        self.assertEqual(code, 2, out)

    # TC-993-12: the strategy, and a bad console block.
    def test_tc_993_12_load_doors_picks_the_strategy(self):
        from signin_kit import console
        st = State(state_dir(self), os.getuid())
        seen = {}

        def transport_for(hosts, stops):
            seen.update(hosts=hosts, stops=stops)
            return object()
        doors, _ = signin.load_doors(self.doors, transport_for, st, seeded_rng())
        self.assertIsInstance(doors["home"].client, console.ConsoleClient)
        self.assertIsInstance(doors["app"].client, console.PublicClient)
        self.assertEqual(seen["hosts"], {"sso-c993.local", "c993.local", "signin.c993.internal"})
        self.assertEqual(seen["stops"], {CONSOLE + "/login", CONSOLE + "/api/auth/callback"})
        doors, _ = signin.load_doors(write_doors(), transport_for, st, seeded_rng())
        self.assertTrue(all(isinstance(d.client, console.PublicClient) for d in doors.values()))

    def test_tc_993_12_a_bad_console_block_is_inconclusive(self):
        good = {"origin": CONSOLE, "methods_route": "/api/me/sign-in-methods", "methods": METHODS993}
        bad = [["not", "an", "object"], dict(good, origin="http://c993.local"), {k: v for k, v in good.items() if k != "origin"},
               {k: v for k, v in good.items() if k != "methods_route"}, {k: v for k, v in good.items() if k != "methods"},
               dict(good, methods={"totp": "authenticator_app"})]
        for block in bad:
            with self.subTest(block=block):
                code, out = self.go("create-account", doors=console_doors(block))
                self.assertEqual(code, 2, out)
                self.assertIn("doors file", out)

    # F-993-04: the WebAuthn negatives at the home door, through the console,
    # with the passkey that signs in alone; PKCE's cannot run there.
    def test_f_993_04_webauthn_negatives_through_the_console(self):
        self.create()
        self.fake.script([P993["login"], None, P993["login"], P993["register-passkey"], None])
        self.assertEqual(self.go("enrol", "passkey")[0], 0)
        self.fake.script([P993["login"]])
        code, out = self.go("negative", "replay")
        self.assertEqual(code, 2, out)
        self.assertIn("no accepted assertion to replay", out)
        self.fake.script([P993["login"], None])
        self.assertEqual(self.go("sign-in", "passkey")[0], 0)
        for name in ("bad-origin", "bad-rpid", "no-up", "no-uv", "bad-signature", "bad-challenge", "replay"):
            with self.subTest(name=name):
                self.fake.script([P993["login"], P993["webauthn-error"]])
                code, out = self.go("negative", name)
                self.assertEqual(code, 0, out)
                self.assertIn("refused: the page login-webauthn-error;", out)
        self.fake.script([P993["login"], None])
        code, out = self.go("negative", "bad-origin")
        self.assertEqual(code, 1, out)
        self.assertIn("admitted", out)
        for name in ("pkce-wrong-verifier", "pkce-absent"):
            with self.subTest(name=name):
                code, out = self.go("negative", name)
                self.assertEqual(code, 2, out)
                self.assertIn("holds the PKCE verifier", out)

    def test_password_totp_takes_the_authenticator_from_another_second_step(self):
        """The door may offer the recovery code first; the code sign-in picks
        the authenticator app instead (cp TC-990-03's otpInstead)."""
        self.create()
        self.fake.script([P993["login"], None, P993["login"], P993["config-totp"], None])
        self.assertEqual(self.go("enrol", "totp")[0], 0)
        select = (f'<html><body data-page-id="login-select-authenticator" data-rasputin-theme="rasputin">'
                  f'<form id="kc-select-credential-form" action="{KC993}/authenticate?s=1" method="post">'
                  '<input type="hidden" name="authenticationExecution" value="ex-recovery"><h2>Recovery '
                  f'Authentication Code</h2></form><form id="kc-select-credential-form" action="{KC993}/authenticate?s=2" '
                  'method="post"><input type="hidden" name="authenticationExecution" value="ex-otp">'
                  '<h2>Authenticator Application</h2></form></body></html>').encode()
        recovery = tpage("login-login-recovery-authn-code-input", [
            ("kc-recovery-code-login-form", {"recoveryCodeInput": ""}),
            ("kc-select-try-another-way-form", {"tryAnotherWay": "on"})])
        self.fake.script([P993["login"], recovery, select, P993["otp"], None])
        code, out = self.go("sign-in", "password-totp")
        self.assertEqual(code, 0, out)
        self.assertEqual(self.fake.posts[-2], {"authenticationExecution": "ex-otp"})
        self.assertIn("otp", self.fake.posts[-1])


if __name__ == "__main__":
    # The tests are loaded from this file's own globals, not by unittest.main,
    # which looks up sys.modules["__main__"]: under python3 -m trace that is
    # trace itself, and no test would run.
    _module = type(sys)("signin_test")
    _module.__dict__.update(globals())
    _result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromModule(_module))
    sys.exit(0 if _result.wasSuccessful() and _result.testsRun else 1)
