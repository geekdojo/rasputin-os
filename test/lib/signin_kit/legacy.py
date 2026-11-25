"""The pre-identity console's passkey ceremony, for the update smoke: an
operator registered on the old image signs in after the update.

    legacy-register --name N   first-run POST /api/auth/register/begin and
                               /finish; passes when finish answers 200 with a
                               rasputin-session cookie
    legacy-sign-in --name N    POST /api/auth/login/begin and /finish with an
                               assertion from the registered key, then
                               GET /api/auth/me, which must answer 200 naming N
    bridge --name N            after the update, the move's bridge
                               (geekdojo/geekdojo-brain#1005): POST
                               /api/auth/bridge/begin and /finish with an
                               assertion from the same key, then
                               /api/auth/bridge/password with the password and
                               email; passes when all three answer 200

The legacy routes are rasputin-control-plane v2026.11.1
api/internal/auth/handlers.go:24-31; the bridge's are its
api/internal/auth/bridge.go (merge e8f75376). The registration is
soft-passkey.py's "none" attestation; the assertion is
passkey.build_assertion, signed by openssl, with user presence and
verification set (the bridge requires verification). The origin is
https://<the options' RP ID>, as a browser on the console's own name would
send.

A refusal (any non-200 at a step, no session cookie, /me naming someone
else) is a failed fact naming the operator and, when the api's coded body
carries one, its code (the bridge's has_password, for one); no HTTP answer
or a TLS failure is Inconclusive (the transport raises it).
"""

import json
import re

from . import passkey
from .errors import FactFailed, Inconclusive

SESSION_COOKIE = "rasputin-session"
# The api's coded refusal body carries {"code": "<word>"}; only a code of this
# shape is repeated in a sentence, never the body's own text.
_CODE = re.compile(r"^[a-z][a-z_]{0,39}$")


class Legacy:
    def __init__(self, transport, state, soft_passkey, passkeys, random_bytes, jar):
        self._t = transport
        self._state = state
        self._soft = soft_passkey
        self._passkeys = passkeys
        self._random = random_bytes
        self._jar = jar

    def _post(self, base, route, name, payload):
        response = self._t.request("POST", base + route, json_body=json.dumps(payload))
        if response.status != 200:
            code = _refusal_code(response)
            said = f"HTTP {response.status} {code}" if code else f"HTTP {response.status}"
            raise FactFailed(f"The console refused {name} at {route} ({said}).",
                             fact=route, http_status=response.status, code=code)
        return response

    @staticmethod
    def _json(response, route, name):
        try:
            answer = json.loads(response.body)
        except ValueError as err:
            raise Inconclusive(f"The console answered {route} for {name} with no JSON.") from err
        if not isinstance(answer, dict):
            raise Inconclusive(f"The console answered {route} for {name} with no JSON object.")
        return answer

    def register(self, base, name):
        route = "/api/auth/register/begin"
        options = self._json(self._post(base, route, name, {"name": name, "displayName": name}), route, name)
        public_key = options.get("publicKey") or {}
        rp_id = (public_key.get("rp") or {}).get("id")
        user_handle = (public_key.get("user") or {}).get("id")
        if not isinstance(rp_id, str) or not rp_id or not isinstance(user_handle, str) or not user_handle:
            raise Inconclusive(f"The registration options for {name} carry no rp.id or user.id.")
        key_path = self._state.key_path(name, "legacy")
        pubkey_der = self._passkeys.make(key_path)
        self._state.add_key_needles(key_path)
        credential_id = self._random(16)
        credential = passkey.encode_registration(self._soft, options, f"https://{rp_id}", pubkey_der,
                                                 credential_id)
        self._post(base, "/api/auth/register/finish", name, credential)
        if not any(c.name == SESSION_COOKIE for c in self._jar):
            raise FactFailed(f"The console registered {name} but issued no {SESSION_COOKIE} cookie.",
                             fact="session")
        self._state.save(name, {"label": name, "key_path": key_path, "rp_id": rp_id,
                                "credential_id": passkey.b64url(credential_id), "user_handle": user_handle})
        return f"{name} registered through the old console ceremony"

    def _assertion(self, base, route, name):
        """Begin a ceremony at route and answer it with the registered key:
        the PublicKeyCredential JSON a finish step takes."""
        account = self._state.load(name)
        options = self._json(self._post(base, route, name, {}), route, name)
        public_key = options.get("publicKey") or {}
        challenge = public_key.get("challenge")
        rp_id = public_key.get("rpId") or account["rp_id"]
        if not isinstance(challenge, str) or not challenge:
            raise Inconclusive(f"The sign-in options for {name} carry no challenge.")
        inputs = passkey.AssertionInputs(
            rp_id=rp_id, origin=f"https://{rp_id}", challenge=challenge,
            credential_id=passkey.b64url_decode(account["credential_id"]), user_handle=account["user_handle"])
        return passkey.build_assertion(inputs, self._passkeys.signer(account["key_path"])).credential()

    def sign_in(self, base, name):
        self._post(base, "/api/auth/login/finish", name, self._assertion(base, "/api/auth/login/begin", name))
        me = self._t.request("GET", base + "/api/auth/me")
        if me.status != 200:
            raise FactFailed(f"/api/auth/me answered HTTP {me.status} after {name} signed in.",
                             fact="/api/auth/me", http_status=me.status)
        if self._json(me, "/api/auth/me", name).get("name") != name:
            raise FactFailed(f"/api/auth/me names another user, not {name}.", fact="/api/auth/me")
        return f"{name} signed in"

    def bridge(self, base, name, password, email):
        """The move's bridge: the old passkey earns a grant, and the grant
        sets the moved account's first password and email. The password and
        email go only in the password step's body."""
        self._post(base, "/api/auth/bridge/finish", name, self._assertion(base, "/api/auth/bridge/begin", name))
        self._post(base, "/api/auth/bridge/password", name, {"password": password, "email": email})
        return f"{name}'s pre-update passkey was accepted and its first password and email were set"


def _refusal_code(response):
    """The code in the api's coded refusal body, or None."""
    try:
        code = json.loads(response.body).get("code")
    except (ValueError, AttributeError):
        return None
    return code if isinstance(code, str) and _CODE.match(code) else None
