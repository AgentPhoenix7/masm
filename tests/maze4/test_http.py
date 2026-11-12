import http.client
import json
import secrets
import sys
import threading
import unittest
from typing import TypedDict

from support import ROOT

sys.path.insert(0, str(ROOT / "assignment-3" / "phone"))
from bridge import App, ControllerServer


class FakePlayer(TypedDict):
    id: int
    owner: int
    state: int
    ready: bool
    pos: int
    steps: int
    penalty: int
    finish: int
    warning: int
    name: str


class FakeState(TypedDict):
    epoch: int
    generation: int
    phase: int
    capacity: int
    count: int
    players: list[FakePlayer]


class FakeLink:
    def __init__(self):
        self.state: FakeState = {
            "epoch": 1,
            "generation": 1,
            "phase": 1,
            "capacity": 8,
            "count": 0,
            "players": [
                {
                    "id": i,
                    "owner": 0,
                    "state": 0,
                    "ready": False,
                    "pos": 100 + i,
                    "steps": 0,
                    "penalty": 0,
                    "finish": 0,
                    "warning": 0,
                    "name": "",
                }
                for i in range(8)
            ],
        }
        self.calls = []

    def latest(self):
        return self.state

    def request(self, op, epoch, payload=b"", request_id=None, **kwargs):
        self.calls.append((op, epoch, payload))
        if op == 2:
            assert request_id is not None
            self.state["players"][0].update(owner=request_id, state=1, name="Alice")
            self.state["count"] = 1
            return 0, 0, request_id
        return 0, 0, 100

    def wait_for(self, predicate, timeout=3):
        assert predicate(self.state)
        return self.state


class HttpTest(unittest.TestCase):
    def setUp(self):
        self.link = FakeLink()
        self.app = App(self.link, "https://maze.example")
        self.app.sync_room()
        self.server = ControllerServer(0, self.app)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)

    def request(self, path, body=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        hs = {"Host": "maze.example"}
        if body is not None:
            hs.update(
                Origin="https://maze.example", **{"Content-Type": "application/json"}
            )
        if headers:
            hs.update(headers)
        data = None if body is None else json.dumps(body)
        conn.request("GET" if body is None else "POST", path, data, hs)
        resp = conn.getresponse()
        result = (resp.status, dict(resp.getheaders()), resp.read())
        conn.close()
        return result

    def test_security_routes(self):
        self.assertEqual(self.request("/api/state")[0], 401)
        self.assertEqual(self.request("/../MAZE4.ASM")[0], 404)
        self.assertEqual(self.request("/api/start", {})[0], 404)
        body = {
            "name": "Alice",
            "password": self.app.password,
            "attempt": secrets.token_hex(16),
        }
        self.assertEqual(
            self.request("/api/join", body, {"Origin": "https://evil.example"})[0], 403
        )
        self.assertEqual(
            self.request("/api/join", body, {"Host": "evil.example"})[0], 403
        )
        status, headers, data = self.request("/api/join", body)
        self.assertEqual(status, 200)
        self.assertIn("Secure", headers["Set-Cookie"])
        self.assertIn("HttpOnly", headers["Set-Cookie"])
        self.assertIn("SameSite=Strict", headers["Set-Cookie"])
        cookie = headers["Set-Cookie"].split(";")[0]
        state = json.loads(data)
        self.assertNotIn("owner", state["player"])
        hs = {"Cookie": cookie, "X-Maze-CSRF": state["csrf"]}
        self.assertEqual(
            self.request("/api/ready", {"ready": True}, {"Cookie": cookie})[0], 403
        )
        self.assertEqual(self.request("/api/ready", {"ready": True}, hs)[0], 200)
        self.link.state["phase"] = 2
        self.assertEqual(
            self.request(
                "/api/input", {"seq": 1, "direction": 4, "tap": True, "player": 7}, hs
            )[0],
            200,
        )
        self.assertEqual(self.link.calls[-1][2][0], 0)
        self.assertEqual(
            self.request("/api/input", {"seq": 1, "direction": 4, "tap": True}, hs)[0],
            409,
        )
        self.assertEqual(
            self.request("/api/input", {"seq": 2, "direction": 99, "tap": False}, hs)[
                0
            ],
            400,
        )
        self.assertEqual(self.request("/api/state", headers={"Cookie": cookie})[0], 200)
        self.link.state["players"][0]["owner"] = 999
        self.assertEqual(self.request("/api/state", headers={"Cookie": cookie})[0], 401)

    def test_login_limit_and_origin_configuration(self):
        for _ in range(120):
            self.assertEqual(self.request("/api/join", {"password": "wrong"})[0], 403)
        self.assertEqual(self.request("/api/join", {"password": "wrong"})[0], 429)
        with self.assertRaises(ValueError):
            App(self.link, "http://public.example")
        with self.assertRaises(ValueError):
            App(self.link, "https://maze.example/extra")


if __name__ == "__main__":
    unittest.main()
