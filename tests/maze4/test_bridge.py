import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "assignment-3" / "phone"))


class ProtocolTests(unittest.TestCase):
    def test_framing(self):
        from protocol import decode, encode

        for data in (b"\x00", bytes(range(256)), b":\n\xff"):
            self.assertEqual(decode(encode(data)), data)
        with self.assertRaises(ValueError):
            decode(b":0001\n")

    def test_snapshot_bounds(self):
        from protocol import decode_state

        with self.assertRaises(ValueError):
            decode_state(b"\x82")


class AuthenticationTests(unittest.TestCase):
    def test_authentication_and_ownership(self):
        from bridge import ApiError, App

        class Link:
            def __init__(self):
                self.state = {
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
                    self.state["players"][0].update(
                        owner=request_id, state=1, name="Alice"
                    )
                    return 0, 0, request_id
                return 0, 0, 123

            def wait_for(self, predicate, timeout=3):
                assert predicate(self.state)
                return self.state

        link = Link()
        app = App(link, "http://127.0.0.1:8080", local_test=True)
        app.sync_room()
        with self.assertRaises(ApiError):
            app.join(
                {"password": "wrong", "name": "Alice", "attempt": "a" * 32}, "local"
            )
        token, session = app.join(
            {"password": app.password, "name": "Alice", "attempt": "a" * 32}, "local"
        )
        self.assertEqual(
            app.join(
                {"password": app.password, "name": "Alice", "attempt": "a" * 32},
                "local",
            )[0],
            token,
        )
        self.assertEqual(sum(c[0] == 2 for c in link.calls), 1)
        self.assertIs(app.authenticate(token), session)
        with self.assertRaises(ApiError):
            app.authenticate("wrong")
        app.input(session, {"seq": 1, "direction": 4, "tap": True, "player": 7})
        self.assertEqual(
            link.calls[-1][2][0], 0
        )  # supplied player field cannot change binding
        with self.assertRaises(ApiError):
            app.input(session, {"seq": 1, "direction": 4, "tap": True})
        link.state["players"][0]["owner"] = 999
        with self.assertRaises(ApiError):
            app.authenticate(token)
        old = app.password
        link.state["epoch"] = 2
        app.sync_room()
        self.assertNotEqual(app.password, old)
        with self.assertRaises(ApiError):
            app.authenticate(token)


class QueueTests(unittest.TestCase):
    def test_movement_does_not_wait_in_a_stale_serial_backlog(self):
        import threading
        import time

        from protocol import SerialLink, TransportError

        link = SerialLink.__new__(SerialLink)
        link.request_lock = threading.Lock()
        link.request_lock.acquire()
        started = time.monotonic()
        with self.assertRaises(TransportError):
            link.request(3, 1, queue_timeout=0.02, retries=1)
        self.assertLess(time.monotonic() - started, 0.2)


class RetryTests(unittest.TestCase):
    def test_uncertain_join_reuses_reserved_owner(self):
        from bridge import App
        from protocol import TransportError
        from test_http import FakeLink

        class UncertainLink(FakeLink):
            def __init__(self):
                super().__init__()
                self.owners = {}
                self.fail_once = True

            def request(self, op, epoch, payload=b"", request_id=None, **kwargs):
                if op != 2:
                    return super().request(op, epoch, payload, request_id, **kwargs)
                if request_id not in self.owners:
                    self.owners[request_id] = len(self.owners)
                slot = self.owners[request_id]
                self.state["players"][slot].update(
                    owner=request_id, state=1, name="Alice"
                )
                self.state["count"] = len(self.owners)
                if self.fail_once:
                    self.fail_once = False
                    raise TransportError("ACK lost after admission")
                return 0, slot, request_id

        link = UncertainLink()
        app = App(link, "https://maze.example")
        app.sync_room()
        body = {"name": "Alice", "password": app.password, "attempt": "f" * 32}
        with self.assertRaises(TransportError):
            app.join(body, "local")
        token, session = app.join(body, "local")
        self.assertEqual(len(link.owners), 1)
        self.assertEqual(session.slot, 0)
        self.assertIs(app.authenticate(token), session)

    def test_dnf_is_readable_but_revoked_owner_is_not(self):
        from bridge import ApiError, App
        from test_http import FakeLink

        link = FakeLink()
        app = App(link, "https://maze.example")
        app.sync_room()
        token, _session = app.join(
            {"name": "Alice", "password": app.password, "attempt": "e" * 32}, "local"
        )
        link.state["phase"] = 2
        link.state["players"][0]["state"] = 3
        app.sync_room()
        self.assertEqual(
            app.private_state(app.authenticate(token))["player"]["state"], 3
        )
        link.state["players"][0]["owner"] = 0
        with self.assertRaises(ApiError):
            app.authenticate(token)


if __name__ == "__main__":
    unittest.main()
