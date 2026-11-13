"""Pure parsers for Keycloak's login pages (26.8.2), ported from
geekdojo/geekdojo-brain#959's kcpages.

Every page carries `data-page-id="login-<template>"` on its body. The client
reads that id first and refuses to guess: an unknown id, a page with no id or
an empty body is Inconclusive, naming the id where there is one. The
Rasputin theme marks every page with `data-rasputin-theme` beside the page id
(identity ui.md §4.1); a page without it is a failed fact, unless the caller
passed --stock-theme (the vector replay and the spike guest: no Rasputin
theme exists yet). Forms are read with their action and inputs; the WebAuthn
arguments are read from the page's inline script, where Keycloak writes each
one as a JavaScript literal.

No function here does I/O.
"""

import base64
import html
import html.parser
import re

from .errors import FactFailed, Inconclusive

# The page ids the client knows, and the step each one is. Each has a fixture
# in rasputin-control-plane's identitytest/testdata/pages/.
KNOWN_PAGES = {
    "login-login": "sign-in form",
    "login-register": "registration form",
    "login-login-otp": "authenticator code",
    "login-webauthn-authenticate": "second-step passkey",
    "login-webauthn-error": "passkey refused",
    "login-webauthn-register": "passkey enrolment",
    "login-select-authenticator": "another way to sign in",
    "login-login-recovery-authn-code-input": "recovery code",
    "login-login-recovery-authn-code-config": "recovery code enrolment",
    "login-login-config-totp": "authenticator app enrolment",
    "login-login-update-password": "new password",
    "login-error": "error",
}

# Pages that are a second step: their presence after a sign-in form means
# the second step ran.
SECOND_STEP_PAGES = frozenset({
    "login-login-otp",
    "login-webauthn-authenticate",
    "login-select-authenticator",
    "login-login-recovery-authn-code-input",
})

_PAGE_ID = re.compile(r'<body\b[^>]*\bdata-page-id="([^"]*)"', re.S)
_THEME = re.compile(r'<(?:html|body)\b[^>]*\bdata-rasputin-theme\b', re.S)


class Form:
    """One <form>: its id, action, method and named inputs."""

    def __init__(self, form_id, action, method):
        self.id = form_id
        self.action = action
        self.method = method
        self.fields = {}


class _FormParser(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.forms = []
        self._current = None
        self.text_by_id = {}
        self._capture = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            self._current = Form(a.get("id") or "", a.get("action") or "",
                                 (a.get("method") or "get").lower())
            self.forms.append(self._current)
        elif tag in ("input", "button", "textarea", "select") and self._current is not None:
            name = a.get("name")
            kind = (a.get("type") or "").lower()
            if (name and not (kind in ("checkbox", "radio") and "checked" not in a)
                    and tag != "button" and kind != "submit"):
                self._current.fields.setdefault(name, a.get("value") or "")
        if "id" in a:
            self._capture.append([a["id"], tag, []])

    def handle_endtag(self, tag):
        if tag == "form":
            self._current = None
        for item in reversed(self._capture):
            if item[1] == tag:
                self._capture.remove(item)
                self.text_by_id.setdefault(item[0], " ".join("".join(item[2]).split()))
                break

    def handle_data(self, data):
        for item in self._capture:
            item[2].append(data)


class Page:
    """A parsed login page."""

    def __init__(self, page_id, forms, text_by_id, raw):
        self.page_id = page_id
        self.step = KNOWN_PAGES[page_id]
        self.forms = forms
        self.text_by_id = text_by_id
        self.raw = raw

    def form(self, form_id):
        for form in self.forms:
            if form.id == form_id:
                return form
        raise Inconclusive(f"The page {self.page_id} has no form {form_id}.", page_id=self.page_id)

    def has_form(self, form_id):
        return any(form.id == form_id for form in self.forms)


def page_id(body):
    """The page's data-page-id, or Inconclusive naming what was missing."""
    if not body or not body.strip():
        raise Inconclusive("The server answered with an empty page.")
    match = _PAGE_ID.search(body)
    if not match or not match.group(1):
        raise Inconclusive("The page has no data-page-id, so the client cannot tell which page it is.")
    found = match.group(1)
    if found not in KNOWN_PAGES:
        raise Inconclusive(f"The page {found} is not one the client knows.", page_id=found)
    return found


def parse(body, stock_theme=False):
    """The page, read by its id; then the theme marker, unless stock_theme."""
    found = page_id(body)
    if not stock_theme and not _THEME.search(body):
        raise FactFailed(f"The page {found} carries no data-rasputin-theme marker, so it is not "
                         f"the Rasputin theme.", fact="theme", page_id=found)
    parser = _FormParser()
    parser.feed(body)
    parser.close()
    return Page(found, parser.forms, parser.text_by_id, body)


# A JavaScript string literal as FreeMarker's ?c writes it, or a bare word.
_JS_VALUE = r'("(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'|[A-Za-z0-9_.\-]+)'
_JS_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "b": "\b", "f": "\f", "v": "\v", "0": "\0"}


def js_literal(text):
    """Decode one JavaScript literal: a quoted string with its escapes, or a
    bare word returned as written."""
    if not text or text[0] not in "\"'":
        return text
    out, i, body = [], 0, text[1:-1]
    while i < len(body):
        ch = body[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if nxt == "u" and re.fullmatch(r"[0-9A-Fa-f]{4}", body[i + 2:i + 6]):
            out.append(chr(int(body[i + 2:i + 6], 16)))
            i += 6
        elif nxt == "x" and re.fullmatch(r"[0-9A-Fa-f]{2}", body[i + 2:i + 4]):
            out.append(chr(int(body[i + 2:i + 4], 16)))
            i += 4
        else:
            out.append(_JS_ESCAPES.get(nxt, nxt))
            i += 2
    return "".join(out)


def script_args(page, names):
    """Each named argument from the page's inline WebAuthn script. A missing
    argument is Inconclusive, never a default."""
    values = {}
    for name in names:
        match = re.search(r"\b" + re.escape(name) + r"\s*:\s*" + _JS_VALUE, page.raw)
        if not match:
            raise Inconclusive(f"The page {page.page_id} does not give the WebAuthn argument {name}.",
                               page_id=page.page_id)
        values[name] = js_literal(match.group(1))
    return values


def totp_secret(page):
    """The authenticator-app secret as base32. In manual mode the page shows
    it; in QR mode only the form's hidden totpSecret carries it, raw, and
    Keycloak's base32 is the encoding of those bytes. Both present must agree."""
    shown = page.text_by_id.get("kc-totp-secret-key", "").replace(" ", "")
    raw = ""
    if page.has_form("kc-totp-settings-form"):
        raw = page.form("kc-totp-settings-form").fields.get("totpSecret", "")
    from_raw = base64.b32encode(raw.encode("utf-8")).decode("ascii").rstrip("=") if raw else ""
    if shown and from_raw and shown.rstrip("=") != from_raw:
        raise Inconclusive(f"The page {page.page_id} shows a secret that differs from its form's.",
                           page_id=page.page_id)
    secret = shown or from_raw
    if not secret:
        raise Inconclusive(f"The page {page.page_id} shows no authenticator-app secret.",
                           page_id=page.page_id)
    return secret


def recovery_codes(page):
    """The recovery codes from the enrolment form's hidden input."""
    for form in page.forms:
        codes = [c for c in form.fields.get("generatedRecoveryAuthnCodes", "").split(",") if c.strip()]
        if codes:
            return codes
    raise Inconclusive(f"The page {page.page_id} gives no recovery codes.", page_id=page.page_id)


def recovery_code_number(page):
    """Which recovery code the input page asks for (1-based)."""
    text = " ".join(page.text_by_id.values())
    match = re.search(r"#\s*(\d+)", text) or re.search(r"#\s*(\d+)", html.unescape(page.raw))
    if not match:
        raise Inconclusive(f"The page {page.page_id} does not say which recovery code it wants.",
                           page_id=page.page_id)
    return int(match.group(1))


def message(page):
    """The feedback sentence a person reads on the page, or ''."""
    for key in ("kc-error-message", "input-error", "input-error-otp-code", "input-error-username"):
        text = page.text_by_id.get(key)
        if text:
            return text
    match = re.search(r'class="[^"]*kc-feedback-text[^"]*"[^>]*>(.*?)</', page.raw, re.S)
    if match:
        return " ".join(html.unescape(re.sub(r"<[^>]+>", "", match.group(1))).split())
    return ""


def select_options(page):
    """The choices on the "another way to sign in" page: (execution id,
    heading) in page order."""
    options = []
    for chunk in page.raw.split('<form id="kc-select-credential-form"')[1:]:
        execution = re.search(r'name="authenticationExecution"\s+value="([^"]+)"', chunk)
        heading = re.search(r"<h2[^>]*>(.*?)</h2>", chunk, re.S)
        if not execution or not heading:
            raise Inconclusive(f"The page {page.page_id} has a choice the client cannot read.",
                               page_id=page.page_id)
        options.append((html.unescape(execution.group(1)), " ".join(html.unescape(heading.group(1)).split())))
    if not options:
        raise Inconclusive(f"The page {page.page_id} offers no choices.", page_id=page.page_id)
    return options
