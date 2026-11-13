"""Key-value log lines on stderr: `level=info event=<step> key=value ...`.

Call sites pass only fields that carry no secret (verb, page, door, HTTP
status). As a backstop, any value equal to one of the run's needles is
written as `[redacted]`.
"""


class Log:
    def __init__(self, stream, needles):
        """stream: where lines go. needles: a callable returning the set of
        secret values this run holds."""
        self._stream = stream
        self._needles = needles

    def _value(self, value, needles):
        text = str(value)
        if text in needles:
            return "[redacted]"
        if not text or any(c.isspace() for c in text) or '"' in text:
            return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'
        return text

    def emit(self, level, event, **fields):
        needles = self._needles()
        parts = [f"level={level}", f"event={self._value(event, needles)}"]
        parts += [f"{k}={self._value(v, needles)}" for k, v in fields.items() if v is not None]
        self._stream.write(" ".join(parts) + "\n")
        self._stream.flush()

    def info(self, event, **fields):
        self.emit("info", event, **fields)

    def warn(self, event, **fields):
        self.emit("warn", event, **fields)

    def error(self, event, **fields):
        self.emit("error", event, **fields)
