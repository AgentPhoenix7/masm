"""Authenticated HTTP-to-COM1 adapter. No maze or movement rules live here."""

import hashlib
import hmac
import json
import re
import secrets
import struct
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from http.cookies import CookieError, SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socket import socket
from typing import TypedDict, cast
from urllib.parse import urlsplit

if __spec__ is not None and __spec__.parent:
    from .protocol import TransportError
else:
    from protocol import TransportError

ASSETS = Path(__file__).parent
ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
# Exactly 32 symbols, avoiding 0, 1, I, and O.
assert len(ALPHABET) == 32
COOKIE = "__Host-maze4"


class ApiError(Exception):
    def __init__(self, status, message):
        self.status, self.message = status, message
        super().__init__(message)


@dataclass
class Session:
    epoch: int
    slot: int
    owner: int
    csrf: str = field(default_factory=lambda: secrets.token_urlsafe(24))
    sequence: int = 0
    heartbeat: float = 0.0
    created: float = field(default_factory=time.monotonic)
    lock: object = field(default_factory=threading.Lock)
    requests: deque = field(default_factory=deque)


class JoinAttempt(TypedDict):
    owner: int
    name: str
    digest: bytes | None
    token: str | None


class App:
    def __init__(self, link, origin=None, *, local_test=False):
        self.link = link
        self.local_test = local_test
        self.origin = None
        self.host = None
        if origin:
            self.set_origin(origin)
        self.lock = threading.RLock()
        self.join_lock = threading.Lock()
        self.epoch = None
        self.password = ""
        self.configured = False
        self.sessions: dict[bytes, Session] = {}
        self.attempts: dict[str, JoinAttempt] = {}
        self.logins = deque()
        self.owners = set()
        self.next_owner = secrets.randbelow(60000) + 1
        self.stopped = threading.Event()
        self.maintenance = None

    def set_origin(self, origin):
        url = urlsplit(origin)
        if (
            url.path not in ("", "/")
            or url.query
            or url.fragment
            or url.username
            or url.password
        ):
            raise ValueError("Origin must contain only scheme and hostname/port")
        if not url.hostname or any(c.isspace() for c in origin):
            raise ValueError("Invalid origin")
        if url.scheme != "https" and not (
            self.local_test
            and url.scheme == "http"
            and url.hostname in ("127.0.0.1", "localhost")
        ):
            raise ValueError("Public origin must use HTTPS")
        self.origin = f"{url.scheme}://{url.netloc}"
        self.host = url.netloc

    def sync_room(self):
        with self.lock:
            state = self.link.latest()
            if state["epoch"] != self.epoch:
                self.epoch = state["epoch"]
                self.password = "".join(secrets.choice(ALPHABET) for _ in range(12))
                self.sessions.clear()
                self.attempts.clear()
                self.owners.clear()
                self.configured = False
            if not self.configured:
                code, _, _ = self.link.request(1, self.epoch, self.password.encode())
                if code:
                    raise TransportError("Room setup rejected")
                self.configured = True
                print(
                    f"Room password: {self.password} (share privately with players)",
                    flush=True,
                )
            live = {
                (p["id"], p["owner"])
                for p in state["players"]
                if p["state"] in (1, 2, 3) and p["owner"] != 0
            }
            self.sessions = {
                k: s
                for k, s in self.sessions.items()
                if (s.slot, s.owner) in live and time.monotonic() - s.created < 86400
            }
            # Keep uncertain reservations for this room: a lost ACK may already
            # have created a MASM player. Never turn a retry into a new owner.
            self.attempts = {
                k: v
                for k, v in self.attempts.items()
                if v["digest"] is None or v["digest"] in self.sessions
            }
        return state

    def start(self):
        def maintain():
            while not self.stopped.wait(0.2):
                try:
                    self.sync_room()
                except TransportError:
                    pass

        self.maintenance = threading.Thread(target=maintain, daemon=True)
        self.maintenance.start()

    def _state(self):
        state = self.link.latest()
        if not self.configured or state["epoch"] != self.epoch:
            raise ApiError(503, "Room is changing; try again shortly")
        return state

    def _digest(self, token):
        return hashlib.sha256(token.encode()).digest()

    def authenticate(self, token):
        state = self._state()
        with self.lock:
            session = (
                self.sessions.get(self._digest(token))
                if token and len(token) < 100
                else None
            )
            if (
                session is None
                or session.epoch != state["epoch"]
                or time.monotonic() - session.created >= 86400
            ):
                raise ApiError(401, "Join this room to control a player")
            player = state["players"][session.slot]
            if player["owner"] != session.owner or player["state"] not in (1, 2, 3):
                self.sessions.pop(self._digest(token), None)
                raise ApiError(401, "Player left or was removed; join again")
            now = time.monotonic()
            while session.requests and now - session.requests[0] > 1:
                session.requests.popleft()
            if len(session.requests) >= 30:
                raise ApiError(429, "Controller request limit reached")
            session.requests.append(now)
            return session

    def join(self, body, client):
        # All connections reach us through loopback. Aggregate login limiting
        # deliberately does not trust caller-supplied forwarding/IP headers.
        with self.join_lock:
            now = time.monotonic()
            while self.logins and now - self.logins[0] > 60:
                self.logins.popleft()
            if len(self.logins) >= 120:
                raise ApiError(429, "Too many join attempts; wait a minute")
            self.logins.append(now)
            state = self._state()
            password = body.get("password")
            if (
                not isinstance(password, str)
                or len(password) > 64
                or not hmac.compare_digest(password.encode(), self.password.encode())
            ):
                raise ApiError(403, "Incorrect room password")
            name, attempt = body.get("name"), body.get("attempt")
            if (
                not isinstance(name, str)
                or not re.fullmatch(r"[ -~]{1,8}", name)
                or not name.strip()
            ):
                raise ApiError(400, "Use 1–8 printable ASCII characters for your name")
            if not isinstance(attempt, str) or not re.fullmatch(
                r"[a-f0-9]{32}", attempt
            ):
                raise ApiError(400, "Invalid join attempt")
            with self.lock:
                cached = self.attempts.get(attempt)
                if cached:
                    if cached["name"] != name:
                        raise ApiError(409, "Use the same name when retrying this join")
                    digest, token = cached["digest"], cached["token"]
                    if (
                        digest is not None
                        and token is not None
                        and digest in self.sessions
                    ):
                        return token, self.sessions[digest]
                    owner = cached["owner"]
                else:
                    if len(self.sessions) >= 8:
                        raise ApiError(409, "Room is full")
                    if len(self.attempts) >= 32:
                        raise ApiError(
                            429,
                            "Too many pending joins; retry an existing join or ask the host for a new room",
                        )
                    for _ in range(65535):
                        self.next_owner = self.next_owner % 65535 + 1
                        if self.next_owner not in self.owners:
                            owner = self.next_owner
                            self.owners.add(owner)
                            break
                    else:
                        raise ApiError(
                            409, "Start a new room before adding more players"
                        )
                    # Reserve before any write/wait; transport errors are uncertain.
                    cached = JoinAttempt(
                        owner=owner, name=name, digest=None, token=None
                    )
                    self.attempts[attempt] = cached
            code, slot, _ = self.link.request(
                2, state["epoch"], name.ljust(8).encode(), request_id=owner
            )
            if code:
                with self.lock:
                    if self.attempts.get(attempt) is cached:
                        self.attempts.pop(attempt, None)
                raise ApiError(
                    409,
                    {1: "Race already started", 2: "Room is full"}.get(
                        code, "Join rejected; try again"
                    ),
                )
            confirmed = self.link.wait_for(
                lambda s: (
                    s["epoch"] != state["epoch"] or s["players"][slot]["owner"] == owner
                )
            )
            if confirmed["epoch"] != state["epoch"]:
                raise TransportError("Room changed; join again")
            token = secrets.token_urlsafe(32)
            session = Session(state["epoch"], slot, owner)
            with self.lock:
                if self.epoch != state["epoch"]:
                    raise ApiError(409, "Room changed; join again")
                digest = self._digest(token)
                self.sessions[digest] = session
                cached.update(digest=digest, token=token)
            return token, session

    def owned_payload(self, session):
        return struct.pack("<BH", session.slot, session.owner)

    def command(self, session, op, extra=b""):
        options = {"queue_timeout": 0.2, "retries": 1} if op == 3 else {}
        code, _, _ = self.link.request(
            op, session.epoch, self.owned_payload(session) + extra, **options
        )
        if code:
            raise ApiError(409, "Game rejected this command; refresh the controller")

    def input(self, session, body):
        seq, direction, tap = body.get("seq"), body.get("direction"), body.get("tap")
        if (
            type(seq) is not int
            or not 0 <= seq < 2**53
            or type(direction) is not int
            or not 0 <= direction <= 4
            or type(tap) is not bool
        ):
            raise ApiError(400, "Invalid movement input")
        with session.lock:
            if seq <= session.sequence:
                raise ApiError(409, "Older movement request ignored")
            # Advance before dispatch: a timed-out older hold must not overtake release.
            session.sequence = seq
            state = self._state()
            self.command(
                session,
                3,
                struct.pack("<HHBB", state["generation"], seq & 65535, direction, tap),
            )
            session.heartbeat = time.monotonic()

    def private_state(self, session):
        with session.lock:
            state = self._state()
            if time.monotonic() - session.heartbeat > 1:
                self.command(session, 4)
                session.heartbeat = time.monotonic()
            player = state["players"][session.slot]
            result = {k: v for k, v in state.items() if k != "players"}
            result.update(
                player={k: v for k, v in player.items() if k != "owner"},
                csrf=session.csrf,
                sequence=session.sequence,
            )
            return result

    def close(self):
        self.stopped.set()
        if self.maintenance:
            self.maintenance.join(4)


class ControllerHandler(BaseHTTPRequestHandler):
    timeout = 4
    server_version = "MAZE4"
    protocol_version = "HTTP/1.0"

    @property
    def app(self) -> App:
        return cast(ControllerServer, self.server).app

    def log_message(self, format, *args):
        pass  # Never log credentials, cookies, request bodies or arbitrary URLs.

    def respond(self, status, body, content_type="application/json", cookie=None):
        if not isinstance(body, bytes):
            body = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        if not self.app.local_test:
            self.send_header("Strict-Transport-Security", "max-age=31536000")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()
        self.wfile.write(body)

    def cookie(self, token="", clear=False):
        secure = "" if self.app.local_test else "; Secure"
        name = "maze4-test" if self.app.local_test else COOKIE
        return f"{name}={token}; Path=/; HttpOnly; SameSite=Strict; Max-Age={0 if clear else 86400}{secure}"

    def session(self):
        try:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            key = "maze4-test" if self.app.local_test else COOKIE
            token = cookies[key].value if key in cookies else ""
        except CookieError:
            token = ""
        return self.app.authenticate(token)

    def route(self, method):
        if self.app.origin is None:
            raise ApiError(503, "Waiting for the HTTPS address")
        if self.headers.get("Host") != self.app.host:
            raise ApiError(403, "Unexpected host")
        if len(self.path) > 128 or "?" in self.path or "#" in self.path:
            raise ApiError(404, "Not found")
        if method == "GET":
            assets = {
                "/": ("controller.html", "text/html; charset=utf-8"),
                "/controller.js": ("controller.js", "text/javascript; charset=utf-8"),
                "/controller.css": ("controller.css", "text/css; charset=utf-8"),
            }
            if self.path in assets:
                name, mime = assets[self.path]
                return self.respond(200, (ASSETS / name).read_bytes(), mime)
            if self.path == "/api/state":
                return self.respond(200, self.app.private_state(self.session()))
            raise ApiError(404, "Not found")
        if self.headers.get("Origin") != self.app.origin:
            raise ApiError(403, "Origin rejected")
        if self.path not in ("/api/join", "/api/input", "/api/ready", "/api/leave"):
            raise ApiError(404, "Not found")
        if (
            self.headers.get("Transfer-Encoding") is not None
            or self.headers.get("Content-Type") != "application/json"
        ):
            raise ApiError(400, "Use JSON with a content length")
        try:
            size = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            size = -1
        if not 0 <= size <= 1024:
            raise ApiError(413, "Request body too large")
        try:
            body = json.loads(self.rfile.read(size))
        except (ValueError, UnicodeError):
            raise ApiError(400, "Invalid JSON")
        if not isinstance(body, dict):
            raise ApiError(400, "JSON object required")
        if self.path == "/api/join":
            # A valid existing cookie makes a reload/retry idempotent.
            try:
                session = self.session()
            except ApiError as exc:
                if exc.status != 401:
                    raise
            else:
                return self.respond(200, self.app.private_state(session))
            token, session = self.app.join(body, self.client_address[0])
            return self.respond(
                200, self.app.private_state(session), cookie=self.cookie(token)
            )
        session = self.session()
        if not hmac.compare_digest(
            self.headers.get("X-Maze-CSRF", "").encode(), session.csrf.encode()
        ):
            raise ApiError(403, "Controller verification failed")
        if self.path == "/api/input":
            self.app.input(session, body)
        elif self.path == "/api/ready":
            if type(body.get("ready")) is not bool:
                raise ApiError(400, "Ready must be true or false")
            self.app.command(session, 6, bytes([body["ready"]]))
        else:
            self.app.command(session, 5)
            with self.app.lock:
                self.app.sessions = {
                    k: s for k, s in self.app.sessions.items() if s is not session
                }
            return self.respond(200, {"left": True}, cookie=self.cookie(clear=True))
        self.respond(200, {"ok": True})

    def handle_route(self, method):
        try:
            self.route(method)
        except ApiError as exc:
            self.respond(exc.status, {"error": exc.message})
        except TransportError as exc:
            self.respond(503, {"error": str(exc)})
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_GET(self):
        self.handle_route("GET")

    def do_POST(self):
        self.handle_route("POST")


class ControllerServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, port, app):
        self.app = app
        self.slots = threading.BoundedSemaphore(32)
        super().__init__(("127.0.0.1", port), ControllerHandler)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            cast(socket, request).close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()
