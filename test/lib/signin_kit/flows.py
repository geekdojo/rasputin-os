"""The Keycloak verbs, driven through Keycloak's own login pages, ported
from geekdojo/geekdojo-brain#959's ceremonies.

Each verb starts a sign-in at one door through that door's client
(console.py: the client's own authorization request with PKCE S256 at stock
Keycloak, or the console's own start on a real image), reads every page by its
data-page-id, posts that page's own form to its action, and ends with the
client's finish (the code exchange, or the console's callback). Nothing here
uses the Admin API: accounts, passwords, authenticator apps, passkeys and
recovery codes are all made on the pages, as a person would. `grant` is not a
verb here: product grants are the api's.

A negative passes when the server refuses it on the page its written reason
names (or, for PKCE, with the OAuth error it names); an admitted negative is
a failed fact named by the negative. admin-password-alone's refusal is the
client's: the error page at stock Keycloak, a second-step page on a real
image (geekdojo/geekdojo-brain#993).
"""

import base64
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
RESET_METHODS = ("passkey", "recovery-code")

# A password reset's return (geekdojo/geekdojo-brain#992): the api's path at
# each door, and the sentence the app door's page shows on success.
RESET_DONE_PATH = "/api/auth/reset-done"
RESET_DONE_SENTENCE = "Your password is changed."

# Each negative: the assertion change it makes, and the refusal it must meet.
NEGATIVES = {
    "bad-origin": {"mutation": "bad-origin", "page": "login-webauthn-error"},
    "bad-rpid": {"mutation": "bad-rpid", "page": "login-webauthn-error"},
    "no-up": {"mutation": "no-up", "page": "login-webauthn-error"},
    "no-uv": {"mutation": "no-uv", "page": "login-webauthn-error"},
    "bad-signature": {"mutation": "bad-signature", "page": "login-webauthn-error"},
    "bad-challenge": {"mutation": "bad-challenge", "page": "login-webauthn-error"},
    "replay": {"mutation": "replay", "page": "login-webauthn-error"},
    "admin-password-alone": {"page": "client"},
    "no-app-access": {"page": "login-error"},
    "pkce-wrong-verifier": {"error": "invalid_grant"},
    "pkce-absent": {"error": "invalid_request"},
}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


class Door:
    """One door: its origin, realm, the client signed in to, and the strategy
    (console.py) that signs in there, which the composition root sets."""

    def __init__(self, name, origin, realm, client_id, redirect_uri, post_logout_uri, client=None):
        self.name = name
        self.client = client
        self.origin = origin.rstrip("/")
        self.host = urllib.parse.urlsplit(self.origin).hostname
        self.client_id = client_id
        self.redirect_uri = redirect_uri
        self.post_logout_uri = post_logout_uri
        self.realm = f"{self.origin}/realms/{realm}"

    def endpoint(self, name):
        return f"{self.realm}/protocol/openid-connect/{name}"


class Trace:
    """The page ids one verb saw, in order, and the facts it reports
    (roles, rp_id) beside them."""

    def __init__(self, stock_theme):
        self.page_ids = []
        self.notes = {}
        self._stock_theme = stock_theme

    def note(self, key, value):
        self.notes[key] = value

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

    @staticmethod
    def _authorize(trace, door, prompt=None, kc_action=None, with_pkce=True):
        """The door's sign-in start, by its client: the page (or Redirect)
        and what the finish needs."""
        return door.client.start(trace, door, prompt=prompt, kc_action=kc_action, with_pkce=with_pkce)

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

    def _passkey_page(self, page):
        page = self._expect(page, "login-login")
        if not page.has_form("webauth"):
            raise FactFailed("The sign-in page offered no passkey sign-in.", fact="passkey offered",
                             page_id=page.page_id)
        return page

    def _passkey_form(self, trace, page, door, account):
        page = self._passkey_page(page)
        trace.note("rp_id", pages.script_args(page, ("rpId",))["rpId"])
        fields = self._assertion(page, door, account["passkey"])
        result = self._post(trace, page.form("webauth"), fields)
        if isinstance(result, Redirect):
            account["last_passkey_assertion"] = fields
        return result

    def _instead(self, trace, page, word, fact):
        """"Try another way" from a second-step page, then the choice whose
        heading holds `word`."""
        if page.page_id != "login-select-authenticator":
            page = self._post(trace, page.form("kc-select-try-another-way-form"), {})
        page = self._expect(page, "login-select-authenticator")
        choice = [ex for ex, heading in pages.select_options(page) if word in heading.lower()]
        if not choice:
            raise FactFailed(f"The other ways to sign in did not include {fact}.",
                             fact=f"{fact} offered", page_id=page.page_id)
        form = next((f for f in page.forms if f.id == "kc-select-credential-form"
                     and f.fields.get("authenticationExecution") == choice[0]), None) \
            or page.form("kc-select-credential-form")
        return self._post(trace, form, {"authenticationExecution": choice[0]})

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
            page = outcome
            if page.page_id != "login-login-otp":
                # The door may offer another second step first (cp TC-990-03's otpInstead).
                page = self._instead(trace, page, "authenticator", "an authenticator code")
            page = self._expect(page, "login-login-otp")
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
            page = self._instead(trace, page, "recovery", "a recovery code")
        page = self._expect(page, "login-login-recovery-authn-code-input")
        number = pages.recovery_code_number(page)
        codes = account.get("recovery_codes") or []
        if not 1 <= number <= len(codes):
            raise Inconclusive(f"The page asked for recovery code {number}, which this account was not given.",
                               page_id=page.page_id)
        return self._post(trace, page.form("kc-recovery-code-login-form"),
                          {"recoveryCodeInput": codes[number - 1]})

    def _answer_sign_in(self, trace, page, door, account, method, password=None):
        """The sign-in step on its page, then the second step `method` asks
        for: a Redirect, or the page after it."""
        if method == "passkey":
            outcome = self._passkey_form(trace, page, door, account)
        else:
            outcome = self._password_form(trace, page, account, password)
        return self._second_step(trace, outcome, door, account, method)

    def _sign_in(self, trace, door, account, method, kc_action=None, password=None):
        """One sign-in to its end: a Redirect, or the page after it."""
        page, pending = self._authorize(trace, door, prompt="login", kc_action=kc_action)
        return self._answer_sign_in(trace, page, door, account, method, password), pending

    def _finish(self, trace, door, outcome, pending, account):
        if not isinstance(outcome, Redirect):
            sentence = pages.message(outcome)
            raise FactFailed(f"The sign-in ended on {outcome.step} ({outcome.page_id}) instead of a token"
                             + (f": {sentence}" if sentence else "."), fact="token", page_id=outcome.page_id)
        if outcome.params.get("kc_action_status") not in (None, "success"):
            raise FactFailed(f"The required action ended with kc_action_status "
                             f"{outcome.params.get('kc_action_status')}.", fact="kc_action_status")
        try:
            door.client.finish(trace, door, outcome, pending, account)
        finally:
            self._state.save(account["label"], account)
        if "roles" in account and pending != "action":
            trace.note("roles", ",".join(account["roles"]) or "none")

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
        page, pending = self._authorize(trace, door, prompt="create")
        page = self._expect(page, "login-register")
        # firstName is required by the realm's user profile (shown as "Name"),
        # and lastName by stock Keycloak's; a realm without one ignores it.
        outcome = self._post(trace, page.form("kc-register-form"), {
            "username": account["username"], "email": f"{account['username']}@signin.invalid",
            "firstName": label, "lastName": "Smoke",
            "password": account["password"], "password-confirm": account["password"]})
        if not isinstance(outcome, Redirect) and outcome.page_id == "login-login-recovery-authn-code-config":
            # During first run the door asks the first account to save its
            # recovery codes (cp flows/actions.go defaultActions; F-993-05).
            outcome = self._save_recovery_codes(trace, outcome, account)
        self._finish(trace, door, outcome, pending, account)

    def _save_recovery_codes(self, trace, page, account):
        account["recovery_codes"] = pages.recovery_codes(page)
        self._state.add_account_needles(account)
        return self._post(trace, page.form("kc-recovery-codes-settings-form"), {})

    def sign_in(self, trace, method, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        outcome, pending = self._sign_in(trace, door, account, method)
        self._finish(trace, door, outcome, pending, account)

    def enrol(self, trace, kind, label, door_name):
        """At stock Keycloak, a sign-in carrying the action. Through the
        console (#1150's launcher), a sign-in for the console session the
        launcher needs, then the launcher's own fresh sign-in."""
        door = self.door(door_name)
        account = self._state.load(label)
        method = self._method_for(account)
        if door.client.launches:
            self.sign_in(trace, method, label, door_name)
            account = self._state.load(label)
        page, pending = door.client.start_action(trace, door, kind, ENROL_ACTIONS[kind], account)
        outcome = self._answer_sign_in(trace, page, door, account, method)
        if kind == "totp":
            page = self._expect(outcome, "login-login-config-totp")
            account["totp_secret"] = pages.totp_secret(page)
            self._state.add_account_needles(account)
            outcome = self._post(trace, page.form("kc-totp-settings-form"),
                                 {"totp": self._totp_code(account), "userLabel": "signin app"})
        elif kind == "recovery-codes":
            outcome = self._save_recovery_codes(
                trace, self._expect(outcome, "login-login-recovery-authn-code-config"), account)
        else:
            page = self._expect(outcome, "login-webauthn-register")
            args = pages.script_args(page, ("challenge", "rpId", "userid"))
            trace.note("rp_id", args["rpId"])
            key_path = self._state.key_path(label, kind)
            pubkey_der = self._passkeys.make(key_path)
            self._state.add_key_needles(key_path)
            credential_id = self._random(16)
            fields = passkey.registration_fields(self._soft, args, door.origin, pubkey_der,
                                                 credential_id, f"signin {kind}")
            outcome = self._post(trace, page.form("register"), fields)
            account["passkey" if kind == "passkey" else "passkey_2fa"] = {
                "key_path": key_path, "credential_id": b64url(credential_id), "userid": args["userid"]}
        self._finish(trace, door, outcome, pending, account)

    def sign_out(self, trace, label, door_name):
        door = self.door(door_name)
        account = self._state.load(label)
        door.client.sign_out(trace, door, account)
        self._state.save(label, account)

    def door_page(self, trace, door_name):
        """One visit to the door's account creation: exit 0 only on the
        Rasputin-themed registration form, which shows that converge has
        applied the console's redirect URI and opened registration
        (F-993-03). Any other answer, a failed fact included, is
        Inconclusive: the poll that calls it waits on."""
        door = self.door(door_name)
        try:
            page, _ = self._authorize(trace, door, prompt="create")
        except FactFailed as err:
            raise Inconclusive(err.sentence) from err
        if isinstance(page, Redirect) or page.page_id != "login-register":
            raise Inconclusive(f"The door answered account creation with "
                               f"{getattr(page, 'page_id', 'a redirect')}, not login-register.",
                               page_id=getattr(page, "page_id", "redirect"))
        return "the door shows its registration form"

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
        self._finish(trace, door, outcome, verifier, account)
        # The old password is refused...
        page, _ = self._authorize(trace, door, prompt="login")
        refused = self._password_form(trace, page, account, account["old_password"])
        if isinstance(refused, Redirect) or refused.page_id != "login-login":
            raise FactFailed("The old password was not refused after the reset.", fact="old password refused",
                             page_id=getattr(refused, "page_id", "redirect"))
        # ...and the new one signs in.
        outcome, verifier = self._sign_in(trace, door, account, self._method_for(account))
        self._finish(trace, door, outcome, verifier, account)

    def reset_password_recovery_code(self, trace, label, door_name):
        """A forgotten password reset with one recovery code
        (geekdojo/geekdojo-brain#992), from the door's own "Forgot your
        password?" link: the account's name, the code the page asks for, a
        privileged account's authenticator code or passkey (never a second
        recovery code), the new password, and the reset's return. Then the
        refresh token the account last held is refused, the old password is
        refused and the new one signs in. Returns what the return said."""
        door = self.door(door_name)
        account = self._state.load(label)
        codes = account.get("recovery_codes") or []
        if not codes:
            raise Inconclusive(f"The account {label} holds no recovery codes to reset with.")
        page, _ = self._authorize(trace, door, prompt="login")
        page = self._expect(page, "login-login")
        start = urllib.parse.urljoin(door.origin + "/", pages.link(page, "rasputin-forgot-password"))
        page = self._expect(trace.see(self._t.navigate("GET", start)), pages.CHOOSE_USER)
        outcome = self._post(trace, page.form("kc-reset-password-form"), {"username": account["username"]})
        page = self._expect(outcome, "login-login-recovery-authn-code-input")
        number = pages.recovery_code_number(page)
        if not 1 <= number <= len(codes):
            raise Inconclusive(f"The page asked for recovery code {number}, which this account was not given.",
                               page_id=page.page_id)
        outcome = self._post(trace, page.form("kc-recovery-code-login-form"), {"recoveryCodeInput": codes[number - 1]})
        if not isinstance(outcome, Redirect) and outcome.page_id == "login-login-otp":
            outcome = self._post(trace, outcome.form("kc-otp-login-form"), {"otp": self._totp_code(account)})
        elif not isinstance(outcome, Redirect) and outcome.page_id == "login-webauthn-authenticate":
            credential = account.get("passkey_2fa") or account.get("passkey")
            if not credential:
                raise FactFailed("The reset asked for a passkey, and this account holds none.",
                                 fact="privileged step", page_id=outcome.page_id)
            outcome = self._post(trace, outcome.form("webauth"), self._assertion(outcome, door, credential))
        page = self._expect(outcome, "login-login-update-password")
        new_password = self._password()
        self._state.add_needles(new_password)
        outcome = self._post(trace, page.form("kc-passwd-update-form"),
                             {"password-new": new_password, "password-confirm": new_password})
        returned = self._reset_returned(trace, outcome)
        old_tokens = account.get("tokens") or {}
        account["old_password"], account["password"], account["tokens"] = account["password"], new_password, {}
        self._state.save(label, account)
        refresh = old_tokens.get("refresh_token")
        if refresh:
            response = self._t.request("POST", door.endpoint("token"), {
                "grant_type": "refresh_token", "refresh_token": refresh, "client_id": door.client_id})
            if response.status == 200:
                raise FactFailed("A session remains after the reset: the old refresh token still refreshes.",
                                 fact="sessions ended", http_status=200)
            if response.status != 400:
                raise Inconclusive(f"The old refresh token's refresh answered HTTP {response.status}, so the "
                                   f"client cannot tell whether its session ended.", http_status=response.status)
        page, _ = self._authorize(trace, door, prompt="login")
        refused = self._password_form(trace, page, account, account["old_password"])
        if isinstance(refused, Redirect) or refused.page_id != "login-login":
            raise FactFailed("The old password was not refused after the reset.", fact="old password refused",
                             page_id=getattr(refused, "page_id", "redirect"))
        outcome, verifier = self._sign_in(trace, door, account, self._method_for(account))
        self._finish(trace, door, outcome, verifier, account)
        return returned

    def _reset_returned(self, trace, outcome):
        """The reset's return: the console's, a redirect the client delivers
        and whose answer must name reset-done; or the app door's page, which
        must say the password is changed."""
        if isinstance(outcome, Redirect):
            if not urllib.parse.urlsplit(outcome.location).path.endswith(RESET_DONE_PATH) or "code" not in outcome.params:
                raise FactFailed("The reset did not return to the reset-done address with a code.",
                                 fact="reset returned")
            answer = self._t.deliver(outcome)
            location = answer.header("Location") or ""
            said = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(location).query)).get("signin", "")
            if said != "reset-done":
                raise FactFailed(f"The console answered the reset's return with {said or 'no outcome'}, "
                                 f"not reset-done.", fact="reset done", http_status=answer.status)
            return "the console answered reset-done"
        page = self._expect(outcome, pages.DOOR_INFO)
        if RESET_DONE_SENTENCE not in " ".join(page.text_by_id.values()) + " " + page.raw:
            raise FactFailed(f"The door's page after the reset says: {pages.message(page) or 'nothing the client reads'}.",
                             fact="reset done", page_id=page.page_id)
        return "the app door said the password is changed"

    def set_password(self, trace, label, door_name, new_password, then_sign_in):
        """Sign in with the account's current password (an administrator's
        temporary one), which Keycloak answers with UPDATE_PASSWORD, and post
        the caller's chosen password there. When the api's door answers with
        its breached-password warning (geekdojo/geekdojo-brain#1145), submit
        the page's own Keep form as rendered: its action, resolved against
        the URL just posted to, and its hidden fields, nothing built here.
        The new password is held in memory only: it is never put in the
        account's state file or the needles file. Returns the outcome."""
        door = self.door(door_name)
        account = self._state.load(label)
        outcome, verifier = self._sign_in(trace, door, account, self._method_for(account))
        page = self._expect(outcome, "login-login-update-password")
        update = page.form("kc-passwd-update-form")
        outcome = self._post(trace, update, {"password-new": new_password, "password-confirm": new_password})
        warned = not isinstance(outcome, Redirect) and outcome.page_id == pages.DOOR_WARNING
        if warned:
            keep = outcome.form("rasputin-keep-form")
            outcome = trace.see(self._t.navigate("POST", urllib.parse.urljoin(update.action, keep.action),
                                                 dict(keep.fields)))
        self._finish(trace, door, outcome, verifier, account)
        # The current password is spent; the new one is not written down.
        account["old_password"] = account.pop("password")
        self._state.save(label, account)
        result = ("breach warning shown, Keep followed, new password set" if warned
                  else "no breach warning, relayed, new password set")
        result += f" (length {len(new_password)})"
        if then_sign_in:
            outcome, verifier = self._sign_in(trace, door, account, self._method_for(account),
                                              password=new_password)
            self._finish(trace, door, outcome, verifier, account)
            result += "; the new password signs in"
        return result

    def negative(self, trace, name, label, door_name):
        expected = NEGATIVES[name]
        door = self.door(door_name)
        account = self._state.load(label)
        if name.startswith("pkce-") and not door.client.own_exchange:
            raise Inconclusive(f"The negative {name} cannot run at the {door.name} door: the api there "
                               f"holds the PKCE verifier, so the client cannot send a wrong or absent one.")
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
            status, answer = door.client.token(door, outcome.code(), pkce.verifier(self._random))
            actual = "admitted" if status == 200 else f"HTTP {status} {answer.get('error')}"
            return self._negative_result(name, status == 400 and answer.get("error") == expected["error"],
                                         actual)
        page, _ = self._authorize(trace, door, prompt="login")
        if "mutation" in expected:
            outcome = self._mutated(trace, page, door, account, label, expected["mutation"])
        else:
            outcome = self._password_form(trace, page, account)
        if isinstance(outcome, Redirect):
            actual = "admitted" if "code" in outcome.params else "a redirect with no code"
            return self._negative_result(name, False, actual)
        refused = (outcome.page_id in door.client.password_alone_refused if expected["page"] == "client"
                   else outcome.page_id == expected["page"])
        return self._negative_result(name, refused, f"the page {outcome.page_id}")

    def _mutated(self, trace, page, door, account, label, mutation):
        """A WebAuthn negative: a second-step passkey's assertion after the
        password, or, for an account whose passkey signs in alone, the
        sign-in page's own passkey form (the home door's path, F-993-04)."""
        if account.get("passkey_2fa"):
            page = self._expect(self._password_form(trace, page, account), "login-webauthn-authenticate")
            credential, replay = account["passkey_2fa"], account.get("last_assertion")
        elif account.get("passkey"):
            page = self._passkey_page(page)
            credential, replay = account["passkey"], account.get("last_passkey_assertion")
        else:
            raise Inconclusive(f"The account {label} holds no passkey for the negative.")
        if mutation == "replay":
            if not replay:
                raise Inconclusive(f"The account {label} holds no accepted assertion to replay.")
            fields = replay
        else:
            fields = self._assertion(page, door, credential, mutation=mutation)
        return self._post(trace, page.form("webauth"), fields)

    @staticmethod
    def _negative_result(name, refused, actual):
        if not refused:
            raise FactFailed(f"The negative {name} was not refused for its written reason: {actual}.",
                             fact=name)
        return actual
