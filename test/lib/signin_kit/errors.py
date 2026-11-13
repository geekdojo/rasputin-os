"""The client's two failure kinds and their exit codes.

A verb ends in one of three ways: its fact held (exit 0), a named fact failed
(FactFailed, exit 1), or the run could not tell (Inconclusive, exit 2). Each
message is the one sentence a person reads; it never carries a secret, a
response body, a cookie or a challenge.
"""

EXIT_PASS = 0
EXIT_FACT_FAILED = 1
EXIT_INCONCLUSIVE = 2


class SigninError(Exception):
    """A verb that did not pass; `exit_code` is what the CLI returns."""

    exit_code = EXIT_INCONCLUSIVE

    def __init__(self, sentence, **fields):
        super().__init__(sentence)
        self.sentence = sentence
        self.fields = fields


class FactFailed(SigninError):
    """A named fact was checked and did not hold."""

    exit_code = EXIT_FACT_FAILED


class Inconclusive(SigninError):
    """The run could not reach the fact: an unknown page, a missing value, no
    HTTP answer, a TLS failure, a bad state directory or bad arguments."""

    exit_code = EXIT_INCONCLUSIVE
