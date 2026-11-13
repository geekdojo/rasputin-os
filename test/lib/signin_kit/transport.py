"""HTTPS for the client: an injected opener, a cookie jar and redirect
capture, ported from geekdojo/geekdojo-brain#959's transport.

The opener sends one request and returns (status, headers, body bytes); the
composition root passes HttpsOpener, tests pass a fake. HttpsOpener verifies
the server against --ca with the SNI and name check set to --server-name (or
the URL's host), presents --client-cert and --client-key when given (direct
Keycloak runs, F-967-06), can send every connection to one --connect address
while the URL keeps its logical host, and bounds each call with a timeout.

A redirect to a host the client does not know (a client's redirect_uri) is
never fetched: it is returned as a Redirect, and the authorization code is
read from its Location. Every cookie value and code the client receives goes
into the state's needles.

Sentences name a call by method, host and path, never a URL with a query,
which can carry a code or a state.
"""

import http.client
import socket
import ssl
import urllib.parse
import urllib.request

from .errors import FactFailed, Inconclusive

MAX_HOPS = 12


class Response:
    """One HTTP answer: status, headers (in order), decoded body and URL."""

    def __init__(self, status, headers, body, url):
        self.status = status
        self.headers = headers
        self.body = body
        self.url = url

    def header(self, name):
        name = name.lower()
        for key, value in self.headers:
            if key.lower() == name:
                return value
        return None


class Redirect:
    """A redirect to a host the client does not fetch, with the parameters
    its Location carries."""

    def __init__(self, location):
        self.location = location
        split = urllib.parse.urlsplit(location)
        self.params = dict(urllib.parse.parse_qsl(split.query))
        if split.fragment:
            self.params.update(urllib.parse.parse_qsl(split.fragment))
        self.target = split._replace(query="", fragment="").geturl()

    def code(self):
        """The authorization code, or a failed fact naming what came back."""
        code = self.params.get("code")
        if code:
            return code
        error = self.params.get("error")
        if error:
            raise FactFailed(f"The redirect to the client carried the error {error} instead of a code.",
                             fact="authorization code", error=error)
        raise FactFailed("The redirect to the client carried no authorization code.",
                         fact="authorization code")


class _HeaderAdapter:
    """Lets http.cookiejar read Set-Cookie from a header list."""

    def __init__(self, headers):
        self._headers = headers

    def info(self):
        return self

    def get_all(self, name, default=None):
        values = [v for k, v in self._headers if k.lower() == name.lower()]
        return values or default


def describe(method, url):
    """The call named for a sentence: method, host and path, no query."""
    split = urllib.parse.urlsplit(url)
    return f"{method} https://{split.hostname}{split.path}"


class Transport:
    """Sends requests through the opener and keeps the cookie jar.

    opener   callable(method, url, headers, body) -> (status, headers, bytes)
    hosts    the hosts the client fetches; a redirect elsewhere is a Redirect
    jar      an http.cookiejar.CookieJar
    secrets  the State, given every cookie value and code received
    log      the Log
    """

    def __init__(self, opener, hosts, jar, secrets, log):
        self._opener = opener
        self._hosts = frozenset(hosts)
        self._jar = jar
        self._secrets = secrets
        self._log = log

    def is_known(self, url):
        return urllib.parse.urlsplit(url).hostname in self._hosts

    def request(self, method, url, fields=None, json_body=None, headers=None):
        """One request; any HTTP status is returned to the caller."""
        if not self.is_known(url):
            raise Inconclusive(f"The client has no address for {describe(method, url)}, so it did "
                               f"not call it.", call=describe(method, url))
        split = urllib.parse.urlsplit(url)
        send = {"Host": split.netloc, "User-Agent": "rasputin-signin-test",
                "Accept": "text/html,application/json;q=0.9,*/*;q=0.8"}
        body = None
        if fields is not None:
            body = urllib.parse.urlencode(fields).encode("utf-8")
            send["Content-Type"] = "application/x-www-form-urlencoded"
        elif json_body is not None:
            body = json_body.encode("utf-8")
            send["Content-Type"] = "application/json"
        send.update(headers or {})
        cookie_request = urllib.request.Request(url, method=method)
        self._jar.add_cookie_header(cookie_request)
        if cookie_request.get_header("Cookie"):
            send["Cookie"] = cookie_request.get_header("Cookie")
        status, header_list, data = self._opener(method, url, send, body)
        self._jar.extract_cookies(_HeaderAdapter(header_list), cookie_request)
        self._secrets.add_needles(*[c.value for c in self._jar])
        self._log.info("http", call=describe(method, url), http=status)
        return Response(status, header_list, data.decode("utf-8", "replace"), url)

    def navigate(self, method, url, fields=None):
        """One request, following redirects to known hosts with GET as a
        browser does. Returns the final Response, or a Redirect to an unknown
        host, which is never fetched. A 5xx is Inconclusive."""
        response = self._checked(self.request(method, url, fields), method, url)
        for _ in range(MAX_HOPS):
            if response.status not in (301, 302, 303, 307, 308):
                return response
            location = response.header("Location")
            if not location:
                raise Inconclusive(f"{describe(method, url)} redirected with no Location.",
                                   call=describe(method, url), http_status=response.status)
            location = urllib.parse.urljoin(response.url, location)
            if not self.is_known(location):
                redirect = Redirect(location)
                self._secrets.add_needles(redirect.params.get("code"))
                return redirect
            response = self._checked(self.request("GET", location), "GET", location)
        raise Inconclusive(f"{describe(method, url)} redirected more than {MAX_HOPS} times.",
                           call=describe(method, url))

    @staticmethod
    def _checked(response, method, url):
        if response.status >= 500:
            raise Inconclusive(f"The server answered {describe(method, url)} with HTTP {response.status}.",
                               call=describe(method, url), http_status=response.status)
        return response


def ssl_context(ca, client_cert=None, client_key=None):
    """TLS verified against the CA file; the client leaf when given."""
    try:
        context = ssl.create_default_context(cafile=ca)
        # Throwaway test CAs sign leaves without an authority key identifier,
        # which Python 3.13's strict mode rejects; chain and name checks stay.
        context.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)
        if client_cert or client_key:
            context.load_cert_chain(client_cert, client_key)
    except (OSError, ssl.SSLError, TypeError) as err:
        raise Inconclusive(f"The TLS files could not be loaded ({type(err).__name__}).") from err
    return context


class _Connection(http.client.HTTPSConnection):
    """An HTTPS connection to `address:port` presenting `server_name`."""

    def __init__(self, server_name, address, port, context, timeout):
        super().__init__(server_name, port, context=context, timeout=timeout)
        self._address = address
        self._server_name = server_name
        self._tls = context

    def connect(self):
        sock = socket.create_connection((self._address, self.port), self.timeout)
        try:
            self.sock = self._tls.wrap_socket(sock, server_hostname=self._server_name)
        except BaseException:
            sock.close()
            raise


class HttpsOpener:
    """The production opener: one HTTPS request per call."""

    def __init__(self, context, connect=None, server_name=None, timeout=30):
        self._context = context
        self._connect = connect
        self._server_name = server_name
        self._timeout = timeout

    def __call__(self, method, url, headers, body):
        split = urllib.parse.urlsplit(url)
        address, port = self._connect or (split.hostname, split.port or 443)
        path = (split.path or "/") + (f"?{split.query}" if split.query else "")
        call = describe(method, url)
        conn = _Connection(self._server_name or split.hostname, address, port, self._context, self._timeout)
        try:
            conn.request(method, path, body=body, headers=headers)
            raw = conn.getresponse()
            return raw.status, raw.getheaders(), raw.read()
        except ssl.SSLError as err:
            raise Inconclusive(f"TLS failed for {call} ({err.reason or type(err).__name__}).",
                               call=call) from err
        except ConnectionRefusedError as err:
            raise Inconclusive(f"The connection for {call} was refused.", call=call) from err
        except (OSError, http.client.HTTPException) as err:
            raise Inconclusive(f"{call} gave no HTTP answer ({type(err).__name__}).", call=call) from err
        finally:
            conn.close()
