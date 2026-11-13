"""The Keycloak verbs, driven through Keycloak's own login pages, ported
from geekdojo/geekdojo-brain#959's ceremonies.

Each verb starts an OpenID Connect authorization request with PKCE S256 at
one door, reads every page by its data-page-id, posts that page's own form to
its action, and ends with the code exchange. Nothing here uses the Admin
API: accounts, passwords, authenticator apps, passkeys and recovery codes are
all made on the pages, as a person would. `grant` is not a verb here:
product grants are the api's.

A negative passes when the server refuses it on the page its written reason
names (or, for PKCE, with the OAuth error it names); an admitted negative is
a failed fact named by the negative.
"""

import base64
import json
import urllib.parse

from . import pages
from . import otp
from . import passkey
from . import pkce
from .errors import FactFailed, Inconclusive
from .transport import Redirect

ENROL_ACTIONS = {
    "totp": "CONFIGURE_TOTP",
    "passkey": "webauthn-register-passwordless",
    "passkey-2fa": "webauthn-register",
    "recovery-codes": "CONFIGURE_RECOVERY_AUTHN_CODES",
}
SIGN_IN_METHODS = ("password", "password-totp", "password-passkey", "passkey", "recovery-code")

# Each negative: the assertion change it makes, and the refusal it must meet.
NEGATIVES = {
    "bad-origin": {"mutation": "bad-origin", "page": "login-webauthn-error"},
    "bad-rpid": {"mutation": "bad-rpid", "page": "login-webauthn-error"},
    "no-up": {"mutation": "no-up", "page": "login-webauthn-error"},
    "no-uv": {"mutation": "no-uv", "page": "login-webauthn-error"},
    "bad-signature": {"mutation": "bad-signature", "page": "login-webauthn-error"},
    "bad-challenge": {"mutation": "bad-challenge", "page": "login-webauthn-error"},
    "replay": {"mutation": "replay", "page": "login-webauthn-error"},
    "admin-password-alone": {"page": "login-error"},
    "no-app-access": {"page": "login-error"},
    "pkce-wrong-verifier": {"error": "invalid_grant"},
    "pkce-absent": {"error": "invalid_request"},
}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def jwt_claims(token):
    """The unverified claims of a JWT, for `sub` only."""
    try:
        return json.loads(passkey.b64url_decode(token.split(".")[1]))
    except (IndexError, ValueError, AttributeError) as err:
        raise Inconclusive("The ID token is not a readable JWT.") from err


class Door:
    """One door: its origin, realm, and the public client signed in to."""

    def __init__(self, name, origin, realm, client_id, redirect_uri, post_logout_uri):
        self.name = name
        self.origin = origin.rstrip("/")
        self.host = urllib.parse.urlsplit(self.origin).hostname
        self.client_id = client_id
        self.redirect_uri = redirect_uri
        self.post_logout_uri = post_logout_uri
        self.realm = f"{self.origin}/realms/{realm}"

    def endpoint(self, name):
        return f"{self.realm}/protocol/openid-connect/{name}"


class Trace:
    """The page ids one verb saw, in order."""

    def __init__(self, stock_theme):
        self.page_ids = []
        self._stock_theme = stock_theme

    def see(self, outcome):
        if isinstance(outcome, Redirect):
            return outcome
        page = pages.parse(outcome.body, self._stock_theme)
        self.page_ids.append(page.page_id)
        return page


class Flows:
    """The Keycloak verbs. Every collaborator arrives through the constructor."""

    def __init__(self, transport, doors, state, soft_passkey, passkeys, clock, random_bytes, log):
        self._t = transport
        self._doors = doors
        self._state = state
        self._soft = soft_passkey
        self._passkeys = passkeys
        self._clock = clock
        self._random = random_bytes
        self._log = log

    # ----- building blocks -------------------------------------------------

    def door(self, name):
        try:
            return self._doors[name]
        except KeyError as err:
            raise Inconclusive(f"The client knows no door named {name}.") from err

    def _other_door(self, door):
        for other in self._doors.values():
            if other.name != door.name:
                return other
        raise Inconclusive("The negative needs a second door, and only one is configured.")

    def _authorize(self, trace, door, prompt=None, kc_action=None, with_pkce=True):
        verifier = pkce.verifier(self._random)
        params = {"client_id": door.client_id, "response_type": "code", "scope": "openid",
                  "redirect_uri": door.redirect_uri, "state": b64url(self._random(12)),
                  "nonce": b64url(self._random(12))}
        if with_pkce:
            params["code_challenge"] = pkce.challenge(verifier)
            params["code_challenge_method"] = "S256"
        if prompt:
            params["prompt"] = prompt
        if kc_action:
            params["kc_action"] = kc_action
        outcome = self._t.navigate("GET", door.endpoint("auth") + "?" + urllib.parse.urlencode(params))
        return trace.see(outcome), verifier

    def _post(self, trace, form, fields):
        merged = dict(form.fields)
        merged.update(fields)
        return trace.see(self._t.navigate("POST", form.action, merged))

    @staticmethod
    def _expect(outcome, *page_ids):
        if isinstance(outcome, Redirect):
            raise FactFailed(f"The server finished the sign-in where the client expected the page "
                             f"{' or '.join(page_ids)}.", fact="page", page_id="redirect")
        if outcome.page_id not in page_ids:
            shown = pages.message(outcome)
            raise FactFailed(f"The server showed {outcome.step} ({outcome.page_id}) where the client "
                             f"expected {' or '.join(page_ids)}" + (f", saying: {shown}" if shown else "")
                             + ("" if shown.endswith(".") else "."),
                             fact="page", page_id=outcome.page_id)
        return outcome

    def _token(self, door, code, verifier):
        response = self._t.request("POST", door.endpoint("token"), {
            "grant_type": "authorization_code", "code": code, "redirect_uri": door.redirect_uri,
            "client_id": door.client_id, "code_verifier": verifier})
        try:
            answer = json.loads(response.body)
        except ValueError as err:
            raise Inconclusive(f"The token endpoint answered HTTP {response.status} with no JSON.",
                               http_status=response.status) from err
        if not isinstance(answer, dict):
            raise Inconclusive(f"The token endpoint answered HTTP {response.status} with no JSON object.")
        return response.status, answer

    def _exchange(self, door, redirect, verifier, account):
        status, answer = self._token(door, redirect.code(), verifier)
        if status != 200:
            raise FactFailed(f"The token endpoint refused the code with {answer.get('error')}.",
                             fact="token", http_status=status)
        account["tokens"] = {k: answer.get(k) for k in ("access_token", "id_token", "refresh_token")}
        self._state.add_account_needles(account)
        sub = jwt_claims(answer.get("id_token", "")).get("sub")
        account.setdefault("user_id", sub)
        if sub != account["user_id"]:
            raise FactFailed("The token was issued for another account.", fact="sub")

    def _totp_code(self, account):
        """The code for the current time step, as an app shows it. Keycloak
        refuses a code it already accepted, so when this step's code was used
        by an earlier sign-in, wait for the clock to reach the next step."""
        key = otp.base32_secret(account["totp_secret"])
        last = account.get("totp_last_step", -1)
        step = otp.totp_step(self._clock.now())
        if step <= last:
            self._log.info("totp-wait", until_step=last + 1)
            self._clock.sleep_until((last + 1) * 30)
            step = otp.totp_step(self._clock.now())
        account["totp_last_step"] = step
        return otp.hotp(key, step)

    def _assertion(self, page, door, credential, mutation=None):
        args = pages.script_args(page, ("challenge", "rpId"))
        inputs = passkey.AssertionInputs(
            rp_id=args["rpId"], origin=door.origin, challenge=args["challenge"],
            credential_id=passkey.b64url_decode(credential["credential_id"]),
            user_handle=credential["userid"])
        signer = self._passkeys.signer(credential["key_path"])
        if mutation:
            other = self._other_door(door)
            return passkey.mutate(mutation, inputs, signer,
                                  {"origin": other.origin, "rp_id": other.host}).fields()
        return passkey.build_assertion(inputs, signer).fields()

    def _password_form(self, trace, page, account, password=None):
        page = self._expect(page, "login-login")
        return self._post(trace, page.form("kc-form-login"), {
            "username": account["username"], "password": password or account["password"]})

    def _passkey_form(self, trace, page, door, account):
        page = self._expect(page, "login-login")
        if not page.has_form("webauth"):
            raise FactFailed("The sign-in page offered no passkey sign-in.", fact="passkey offered",
                             page_id=page.page_id)
        return self._post(trace, page.form("webauth"), self._assertion(page, door, account["passkey"]))

    def _second_step(self, trace, outcome, door, account, method):
        """Answer the second step `method` asks for, or refuse one it doesn't."""
        if isinstance(outcome, Redirect) or outcome.page_id not in pages.SECOND_STEP_PAGES:
            if method in ("password-totp", "password-passkey", "recovery-code"):
                raise FactFailed("The server asked for no second step, but this sign-in needs one.",
                                 fact="second step asked", page_id=getattr(outcome, "page_id", "redirect"))
            return outcome
        if method in ("password", "passkey"):
            raise FactFailed(f"The server asked for a second step ({outcome.page_id}), but this "
                             f"sign-in expects none.", fact="no second step", page_id=outcome.page_id)
        if method == "password-totp":
            page = self._expect(outcome, "login-login-otp")
            return self._post(trace, page.form("kc-otp-login-form"), {"otp": self._totp_code(account)})
        if method == "password-passkey":
            page = self._expect(outcome, "login-webauthn-authenticate")
            fields = self._assertion(page, door, account["passkey_2fa"])
            result = self._post(trace, page.form("webauth"), fields)
            if isinstance(result, Redirect):
                account["last_assertion"] = fields
            return result
        # recovery-code: "try another way", choose recovery codes, enter one.
        page = outcome
        if page.page_id != "login-login-recovery-authn-code-input":
            if page.page_id != "login-select-authenticator":
                page = self._post(trace, page.form("kc-select-try-another-way-form"), {})
            page = self._expect(page, "login-select-authenticator")
            choice = [ex for ex, heading in pages.select_options(page) if "recovery" in heading.lower()]
            if not choice:
                raise FactFailed("The other ways to sign in did not include a recovery code.",
                                 fact="recovery code offered", page_id=page.page_id)
            form = [f for f in page.forms if f.id == "kc-select-credential-form"
                    and f.fields.get("authenticationExecution") == choice[0]][0]
            page = self._post(trace, form, {})
        page = self._expect(page, "login-login-recovery-authn-code-input")
        number = pages.recovery_code_number(page)
        codes = account.get("recovery_codes") or []
        if not 1 <= number <= len(codes):
            raise Inconclusive(f"The page asked for recovery code {number}, which this account was not given.",
                               page_id=page.page_id)
        return self._post(trace, page.form("kc-recovery-code-login-form"),
                          {"recoveryCodeInput": codes[number - 1]})

    def _sign_in(self, trace, door, account, method, kc_action=None, password=None):
        """One sign-in to its end: a Redirect, or the page after it."""
        page, verifier = self._authorize(trace, door, prompt="login", kc_action=kc_action)
        if method == "passkey":
            outcome = self._passkey_form(trace, page, door, account)
        else:
            outcome = self._password_form(trace, page, account, password)
        return self._second_step(trace, outcome, door, account, method), verifier

    def _finish(self, door, outcome, verifier, account):
        if not isinstance(outcome, Redirect):
            sentence = pages.message(outcome)
            raise FactFailed(f"The sign-in ended on {outcome.step} ({outcome.page_id}) instead of a token"
                             + (f": {sentence}" if sentence else "."), fact="token", page_id=outcome.page_id)
        if outcome.params.get("kc_action_status") not in (None, "success"):
            raise FactFailed(f"The required action ended with kc_action_status "
                             f"{outcome.params.get('kc_action_status')}.", fact="kc_action_status")
        try:
            self._exchange(door, outcome, verifier, account)
        finally:
            self._state.save(account["label"], account)

    def _password(self):
        return b64url(self._random(18))

    @staticmethod
    def _method_for(account):
        return "password-totp" if account.get("totp_secret") else "password"

    # ----- verbs -------------------------------------------------------------

    def create_account(self, trace, label, door_name):
        door = self.door(door_name)
        account = {"label": label, "username": f"{label}-{self._random(4).hex()}",
                   "password": self._password()}
        self._state.add_account_needles(account)
        page, verifier = self._authorize(trace, door, prompt="create")
        page = self._expect(page, "login-register")
        outcome = self._post(trace, page.form("kc-register-form"), {
            "username": account["username"], "email": f"{account['username']}@signin.invalid",
            "password": account["password"], "password-confirm": account["password"]})
        self._finish(door, outcome, verifier, account)

    def sign_in(self, trace, method, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        outcome, verifier = self._sign_in(trace, door, account, method)
        self._finish(door, outcome, verifier, account)

    def enrol(self, trace, kind, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        outcome, verifier = self._sign_in(trace, door, account, self._method_for(account),
                                          kc_action=ENROL_ACTIONS[kind])
        if kind == "totp":
            page = self._expect(outcome, "login-login-config-totp")
            account["totp_secret"] = pages.totp_secret(page)
            self._state.add_account_needles(account)
            outcome = self._post(trace, page.form("kc-totp-settings-form"),
                                 {"totp": self._totp_code(account), "userLabel": "signin app"})
        elif kind == "recovery-codes":
            page = self._expect(outcome, "login-login-recovery-authn-code-config")
            account["recovery_codes"] = pages.recovery_codes(page)
            self._state.add_account_needles(account)
            outcome = self._post(trace, page.form("kc-recovery-codes-settings-form"), {})
        else:
            page = self._expect(outcome, "login-webauthn-register")
            args = pages.script_args(page, ("challenge", "rpId", "userid"))
            key_path = self._state.key_path(label, kind)
            pubkey_der = self._passkeys.make(key_path)
            self._state.add_key_needles(key_path)
            credential_id = self._random(16)
            fields = passkey.registration_fields(self._soft, args, door.origin, pubkey_der,
                                                 credential_id, f"signin {kind}")
            outcome = self._post(trace, page.form("register"), fields)
            account["passkey" if kind == "passkey" else "passkey_2fa"] = {
                "key_path": key_path, "credential_id": b64url(credential_id), "userid": args["userid"]}
        self._finish(door, outcome, verifier, account)

    def sign_out(self, trace, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        id_token = (account.get("tokens") or {}).get("id_token")
        if not id_token:
            raise Inconclusive(f"The account {label} holds no ID token to sign out with.")
        query = urllib.parse.urlencode({"id_token_hint": id_token, "client_id": door.client_id,
                                        "post_logout_redirect_uri": door.post_logout_uri})
        outcome = trace.see(self._t.navigate("GET", door.endpoint("logout") + "?" + query))
        if not isinstance(outcome, Redirect) or outcome.target != door.post_logout_uri:
            raise FactFailed("The sign-out did not return to the client's signed-out page.",
                             fact="signed out", page_id=getattr(outcome, "page_id", "redirect"))
        account["tokens"] = {}
        self._state.save(label, account)

    def reset_password_passkey(self, trace, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        outcome, verifier = self._sign_in(trace, door, account, "passkey", kc_action="UPDATE_PASSWORD")
        page = self._expect(outcome, "login-login-update-password")
        new_password = self._password()
        self._state.add_needles(new_password)
        outcome = self._post(trace, page.form("kc-passwd-update-form"),
                             {"password-new": new_password, "password-confirm": new_password})
        account["old_password"], account["password"] = account["password"], new_password
        self._finish(door, outcome, verifier, account)
        # The old password is refused...
        page, _ = self._authorize(trace, door, prompt="login")
        refused = self._password_form(trace, page, account, account["old_password"])
        if isinstance(refused, Redirect) or refused.page_id != "login-login":
            raise FactFailed("The old password was not refused after the reset.", fact="old password refused",
                             page_id=getattr(refused, "page_id", "redirect"))
        # ...and the new one signs in.
        outcome, verifier = self._sign_in(trace, door, account, self._method_for(account))
        self._finish(door, outcome, verifier, account)

    def negative(self, trace, name, label, door_name):
        expected = NEGATIVES[name]
        door = self.door(door_name)
        account = self._state.load(label)
        if name == "pkce-absent":
            outcome, _ = self._authorize(trace, door, prompt="login", with_pkce=False)
            actual = (outcome.params.get("error") or "a redirect with no error") if isinstance(outcome, Redirect) \
                else f"the page {outcome.page_id}"
            return self._negative_result(name, actual == expected["error"], actual)
        if name == "pkce-wrong-verifier":
            outcome, _ = self._sign_in(trace, door, account, self._method_for(account))
            if not isinstance(outcome, Redirect):
                raise Inconclusive(f"The sign-in before the wrong verifier ended on {outcome.page_id}.",
                                   page_id=outcome.page_id)
            status, answer = self._token(door, outcome.code(), pkce.verifier(self._random))
            actual = "admitted" if status == 200 else f"HTTP {status} {answer.get('error')}"
            return self._negative_result(name, status == 400 and answer.get("error") == expected["error"],
                                         actual)
        page, _ = self._authorize(trace, door, prompt="login")
        outcome = self._password_form(trace, page, account)
        if "mutation" in expected:
            page = self._expect(outcome, "login-webauthn-authenticate")
            if expected["mutation"] == "replay":
                fields = account.get("last_assertion")
                if not fields:
                    raise Inconclusive(f"The account {label} holds no accepted assertion to replay.")
            else:
                fields = self._assertion(page, door, account["passkey_2fa"], mutation=expected["mutation"])
            outcome = self._post(trace, page.form("webauth"), fields)
        if isinstance(outcome, Redirect):
            actual = "admitted" if "code" in outcome.params else "a redirect with no code"
            return self._negative_result(name, False, actual)
        return self._negative_result(name, outcome.page_id == expected["page"], f"the page {outcome.page_id}")

    @staticmethod
    def _negative_result(name, refused, actual):
        if not refused:
            raise FactFailed(f"The negative {name} was not refused for its written reason: {actual}.",
                             fact=name)
        return actual
