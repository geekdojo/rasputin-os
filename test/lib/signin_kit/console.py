"""The two ways a door is signed in to (geekdojo/geekdojo-brain#993).

PublicClient is the stock-Keycloak path the vectors replay: the client builds
the authorization request with PKCE S256 itself and exchanges the code at the
token endpoint, as a public client. An enrolment is a kc_action on that
request.

ConsoleClient is the customer's path through the console at
https://<cid>.local, the one a fresh image serves. Every Rasputin client is
confidential and the api holds the PKCE verifier, so the client never builds
an authorization request or touches a token:

  start    GET /api/auth/signin (/api/auth/signup for an account's creation),
           followed through the api's 303 to the home door's page.
  finish   the door's code redirect delivered to /api/auth/callback with the
           pending cookie; the answer must be a 303 to /login with no signin
           key. A sign-in's return must set __Host-rasputin-session, and
           GET /api/auth/me must then answer 200 naming the account; its roles
           are reported. An action's return mints no session (#1150), and is
           not read with /me: the grant it may submit ends the account's
           sessions on its own time, so the caller waits on that fact itself.
  enrol    with a console session in the jar, POST the sign-in-methods route
           (data from the doors file, with its method map) with JSON
           {"method": m}; the 200's `next` is GET in the same jar, and its 303
           leads to the home door's fresh sign-in (prompt=login), then the
           action's page.
  sign-out POST /api/auth/logout with the session the account's state holds;
           GET /api/auth/me with that same cookie must then answer 401.

The console's launcher (/login) and callback are known hosts' paths the
transport never follows (its stops), so each arrives here as a Redirect.
Sentences name a key or a status, never a cookie, code or query.
"""

import json
import urllib.parse

from . import pages
from . import passkey
from . import pkce
from .errors import FactFailed, Inconclusive
from .transport import Redirect

SESSION_COOKIE = "__Host-rasputin-session"
CALLBACK_PATH = "/api/auth/callback"
LAUNCHER_PATH = "/login"
ACTION_START = "/api/auth/signin?action="
SIGNIN_PATH = "/api/auth/signin"
SIGNUP_PATH = "/api/auth/signup"
ME_PATH = "/api/auth/me"
LOGOUT_PATH = "/api/auth/logout"

# What a pending sign-in is waiting to finish: a sign-in that mints a
# session, or an action's fresh sign-in, which mints none.
SIGN_IN = "sign-in"
ACTION = "action"


def b64url(data):
    return passkey.b64url(data)


def jwt_claims(token):
    """The unverified claims of a JWT, for `sub` only."""
    try:
        return json.loads(passkey.b64url_decode(token.split(".")[1]))
    except (IndexError, ValueError, AttributeError) as err:
        raise Inconclusive("The ID token is not a readable JWT.") from err


class PublicClient:
    """Stock Keycloak: the client's own authorization request and token
    exchange. Every collaborator arrives through the constructor."""

    # An enrolment is a kc_action on the client's own sign-in.
    launches = False
    # The client holds the PKCE verifier, so the PKCE negatives can run.
    own_exchange = True
    # A privileged account's password alone ends on the error page at stock
    # Keycloak, where no second-step policy is installed (the vectors' N8).
    password_alone_refused = frozenset({"login-error"})

    def __init__(self, transport, state, random_bytes):
        self._t = transport
        self._state = state
        self._random = random_bytes

    def start(self, trace, door, prompt=None, kc_action=None, with_pkce=True):
        """The authorization request: the page it lands on (or a Redirect)
        and the verifier the finish needs."""
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

    def start_action(self, trace, door, kind, kc_action, account):
        """An enrolment: a fresh sign-in carrying the action."""
        return self.start(trace, door, prompt="login", kc_action=kc_action)

    def token(self, door, code, verifier):
        """One code exchange: (HTTP status, the JSON object answered)."""
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

    def finish(self, trace, door, redirect, verifier, account):
        """The code exchange; the tokens go into the account."""
        status, answer = self.token(door, redirect.code(), verifier)
        if status != 200:
            raise FactFailed(f"The token endpoint refused the code with {answer.get('error')}.",
                             fact="token", http_status=status)
        account["tokens"] = {k: answer.get(k) for k in ("access_token", "id_token", "refresh_token")}
        self._state.add_account_needles(account)
        sub = jwt_claims(answer.get("id_token", "")).get("sub")
        account.setdefault("user_id", sub)
        if sub != account["user_id"]:
            raise FactFailed("The token was issued for another account.", fact="sub")

    def sign_out(self, trace, door, account):
        """RP-initiated logout with the ID token; the door must return to the
        client's signed-out page."""
        id_token = (account.get("tokens") or {}).get("id_token")
        if not id_token:
            raise Inconclusive(f"The account {account['label']} holds no ID token to sign out with.")
        query = urllib.parse.urlencode({"id_token_hint": id_token, "client_id": door.client_id,
                                        "post_logout_redirect_uri": door.post_logout_uri})
        outcome = trace.see(self._t.navigate("GET", door.endpoint("logout") + "?" + query))
        if not isinstance(outcome, Redirect) or outcome.target != door.post_logout_uri:
            raise FactFailed("The sign-out did not return to the client's signed-out page.",
                             fact="signed out", page_id=getattr(outcome, "page_id", "redirect"))
        account["tokens"] = {}


class ConsoleClient:
    """The console's path at https://<cid>.local. Every collaborator arrives
    through the constructor; the route and the method map are the doors
    file's data."""

    launches = True
    # The api holds the verifier: a wrong or absent one cannot be driven.
    own_exchange = False
    # The real flow refuses a privileged account's password alone by asking
    # for its second step (cp firstrun_functional_test.go's TC-990-03).
    password_alone_refused = pages.SECOND_STEP_PAGES

    def __init__(self, transport, state, origin, methods_route, methods):
        self._t = transport
        self._state = state
        self.origin = origin.rstrip("/")
        self.host = urllib.parse.urlsplit(self.origin).hostname
        self._route = methods_route
        self._methods = dict(methods)

    def _url(self, path):
        return self.origin + path

    @staticmethod
    def stops(origin):
        """The console's paths the transport returns as a Redirect."""
        origin = origin.rstrip("/")
        return {origin + LAUNCHER_PATH, origin + CALLBACK_PATH}

    def _to_door(self, trace, path, fact):
        """GET path at the console, followed to the door's page. The console
        sending the browser to its launcher instead is a failed fact naming
        the key it gave."""
        outcome = self._t.navigate("GET", self._url(path))
        if isinstance(outcome, Redirect):
            if outcome.target == self._url(LAUNCHER_PATH):
                key = outcome.params.get("signin")
                raise FactFailed(f"The console answered {path.split('?')[0]} with its launcher"
                                 + (f" and signin={key}" if key else " and no outcome")
                                 + " instead of the door.", fact=fact)
            raise FactFailed(f"The console sent {path.split('?')[0]} to a page the client does not "
                             f"fetch instead of the door.", fact=fact)
        return outcome

    def start(self, trace, door, prompt=None, kc_action=None, with_pkce=True):
        if kc_action or not with_pkce:
            raise Inconclusive("At a console door the api builds the authorization request and holds "
                               "its verifier, so the client cannot add a kc_action or drop PKCE.")
        path = SIGNUP_PATH if prompt == "create" else SIGNIN_PATH
        return trace.see(self._to_door(trace, path, "console start")), SIGN_IN

    def start_action(self, trace, door, kind, kc_action, account):
        """POST the sign-in-methods route with the method for `kind`, GET its
        `next` in the same jar, and follow it to the door's fresh sign-in."""
        method = self._methods[kind]
        call = f"POST {self._route}"
        response = self._t.request("POST", self._url(self._route), json_body=json.dumps({"method": method}))
        if response.status >= 500:
            raise Inconclusive(f"The console answered {call} with HTTP {response.status}.",
                               http_status=response.status)
        if response.status == 409:
            raise FactFailed(f"The console refused {method} at {call} with HTTP 409: "
                             f"{_sentence(response.body) or 'no sentence'}", fact="clock", http_status=409)
        if response.status != 200:
            raise FactFailed(f"The console refused {method} at {call} with HTTP {response.status}"
                             + (f": {_sentence(response.body)}" if _sentence(response.body) else "."),
                             fact="enrol start", http_status=response.status)
        try:
            nxt = json.loads(response.body).get("next")
        except (ValueError, AttributeError) as err:
            raise Inconclusive(f"The console answered {call} 200 with no JSON object.") from err
        if not isinstance(nxt, str) or not nxt.startswith(ACTION_START) or len(nxt) == len(ACTION_START):
            raise Inconclusive(f"The console answered {call} 200 with no next of the form {ACTION_START}<kind>.")
        outcome = self._to_door(trace, nxt, "enrol start")
        if outcome.status == 400 or _page_id_of(outcome) in ("login-error", pages.DOOR_REFUSAL):
            page = trace.see(outcome)
            said = pages.message(page) or " ".join(page.text_by_id.values())[:200]
            raise FactFailed(f"The door refused the action {method} forwarded ({page.page_id})"
                             + (f": {said}" if said else "."), fact="kc_action", page_id=page.page_id)
        return trace.see(outcome), ACTION

    def finish(self, trace, door, redirect, pending, account):
        if redirect.target != self._url(CALLBACK_PATH):
            raise FactFailed("The door returned somewhere other than the console's callback.",
                             fact="console callback")
        answer = self._t.deliver(redirect)
        location = urllib.parse.urljoin(self.origin + "/", answer.header("Location") or "")
        landed = Redirect(location)
        key = landed.params.get("signin")
        if answer.status != 303 or landed.target != self._url(LAUNCHER_PATH) or key:
            raise FactFailed("The console answered the door's return with "
                             + (f"signin={key}" if key else f"HTTP {answer.status} and no launcher")
                             + ".", fact="console callback", http_status=answer.status)
        session = _set_cookie(answer, SESSION_COOKIE)
        if pending == ACTION:
            if session:
                raise FactFailed("The action's return set a console session, and an action mints none.",
                                 fact="action return")
            return
        if not session:
            raise FactFailed("The console's callback set no session cookie.", fact="session")
        self._state.add_needles(session)
        account["console_session"] = session
        account["roles"] = self._me(account)

    def _me(self, account):
        response = self._t.request("GET", self._url(ME_PATH))
        if response.status != 200:
            raise FactFailed(f"GET {ME_PATH} answered HTTP {response.status} after the sign-in.",
                             fact="me", http_status=response.status)
        try:
            me = json.loads(response.body)
            name, roles = me.get("name"), me.get("roles")
        except (ValueError, AttributeError) as err:
            raise FactFailed(f"GET {ME_PATH} answered 200 with no JSON object.", fact="me") from err
        if name != account["username"]:
            raise FactFailed(f"GET {ME_PATH} named another account.", fact="me")
        if not isinstance(roles, list) or not all(isinstance(r, str) for r in roles):
            raise FactFailed(f"GET {ME_PATH} gave no list of roles.", fact="me")
        return roles

    def sign_out(self, trace, door, account):
        session = account.get("console_session")
        if not session:
            raise Inconclusive(f"The account {account['label']} holds no console session to sign out with.")
        self._t.add_cookie(self.host, SESSION_COOKIE, session)
        response = self._t.request("POST", self._url(LOGOUT_PATH))
        if response.status != 200:
            raise FactFailed(f"POST {LOGOUT_PATH} answered HTTP {response.status}.", fact="signed out",
                             http_status=response.status)
        # The same cookie again: the server, not the jar, must have ended it.
        self._t.add_cookie(self.host, SESSION_COOKIE, session)
        me = self._t.request("GET", self._url(ME_PATH))
        if me.status != 401:
            raise FactFailed(f"GET {ME_PATH} with the signed-out session answered HTTP {me.status}, not 401.",
                             fact="signed out", http_status=me.status)
        account.pop("console_session", None)


def _set_cookie(response, name):
    """The value response's Set-Cookie gives `name`, or '' when it sets none
    or clears it."""
    for key, value in response.headers:
        if key.lower() == "set-cookie" and value.startswith(name + "="):
            got = value[len(name) + 1:].split(";", 1)[0].strip()
            if got:
                return got
    return ""


def _sentence(body):
    """The `error` sentence of a coded JSON error, or ''."""
    try:
        said = json.loads(body).get("error")
    except (ValueError, AttributeError):
        return ""
    return said if isinstance(said, str) else ""


def _page_id_of(response):
    try:
        return pages.page_id(response.body)
    except Inconclusive:
        return ""
