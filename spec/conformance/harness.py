"""
Tiny black-box test harness for the Gatecrash conformance suite.

Deliberately stdlib-only and deliberately dumb. It speaks HTTP and nothing else:
no ORM, no fixtures library, no knowledge of the app it is testing. That
constraint is the point — if a test could only be written by reaching inside the
app, it does not belong in this suite.
"""

import json
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field


class Failure(AssertionError):
    pass


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

@dataclass
class Response:
    status: int
    headers: dict
    raw: bytes

    @property
    def json(self):
        try:
            return json.loads(self.raw)
        except Exception:
            return None

    def __repr__(self):
        body = self.raw[:400].decode("utf-8", "replace")
        return f"<{self.status} {body}>"


class Client:
    def __init__(self, base_url, admin_token=None, timeout=15):
        self.base = base_url.rstrip("/")
        self.admin_token = admin_token
        self.timeout = timeout

    def request(self, method, path, *, body=None, headers=None, admin=False):
        url = path if path.startswith("http") else self.base + path
        hdrs = {"Accept": "application/json"}
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            hdrs["Content-Type"] = "application/json"
        if admin and self.admin_token:
            hdrs["Authorization"] = f"Bearer {self.admin_token}"
        hdrs.update(headers or {})

        req = urllib.request.Request(url, data=data, method=method, headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                return Response(r.status, dict(r.headers), r.read())
        except urllib.error.HTTPError as e:
            return Response(e.code, dict(e.headers), e.read())
        except Exception as e:
            raise Failure(f"{method} {url} did not respond: {e}") from e

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, **kw):
        return self.request("POST", path, **kw)


def in_parallel(fn, n):
    """Fire `fn(i)` on n threads released as close to simultaneously as possible."""
    gate = threading.Barrier(n)
    out = [None] * n

    def worker(i):
        gate.wait()
        try:
            out[i] = fn(i)
        except Exception as e:
            out[i] = e

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return out


# --------------------------------------------------------------------------- #
# assertions
# --------------------------------------------------------------------------- #

def expect(cond, msg, actual=None):
    if not cond:
        raise Failure(f"{msg}" + (f"\n        got: {actual!r}" if actual is not None else ""))


def expect_status(resp, want, what=""):
    expect(resp.status == want,
           f"expected {want} {what}".rstrip(), f"{resp.status} {resp.raw[:300]!r}")


def poll_until(fn, *, timeout=15.0, interval=0.25, what="condition"):
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        last = fn()
        if last:
            return last
        time.sleep(interval)
    raise Failure(f"timed out after {timeout}s waiting for {what}")


def walk(node, path="$"):
    """Yield (json_pointer, value) for every node in a parsed JSON document."""
    yield path, node
    if isinstance(node, dict):
        for k, v in node.items():
            yield from walk(v, f"{path}.{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from walk(v, f"{path}[{i}]")


# --------------------------------------------------------------------------- #
# registry
# --------------------------------------------------------------------------- #

@dataclass
class Case:
    id: str
    title: str
    fn: object
    chapter: str = ""


REGISTRY: list = []


def case(id, title, chapter=""):
    def deco(fn):
        REGISTRY.append(Case(id=id, title=title, fn=fn, chapter=chapter))
        return fn
    return deco


@dataclass
class Result:
    case: Case
    ok: bool
    error: str = ""
    skipped: bool = False
    seconds: float = 0.0


def run(cases, ctx) -> list:
    results = []
    for c in cases:
        started = time.time()
        try:
            c.fn(ctx)
            results.append(Result(c, True, seconds=time.time() - started))
        except Skip as e:
            results.append(Result(c, True, error=str(e), skipped=True,
                                  seconds=time.time() - started))
        except Failure as e:
            results.append(Result(c, False, str(e), seconds=time.time() - started))
        except Exception as e:
            results.append(Result(c, False, f"{type(e).__name__}: {e}",
                                  seconds=time.time() - started))
    return results


class Skip(Exception):
    pass


@dataclass
class Ctx:
    """Everything a case is allowed to touch."""
    app: Client
    psp: Client
    seed: dict
    extra: dict = field(default_factory=dict)

    def ticket_type(self, name):
        for ev in self.seed["events"]:
            for tt in ev["ticket_types"]:
                if tt["name"] == name:
                    return ev, tt
        raise Failure(f"no seeded ticket type named {name!r}")
