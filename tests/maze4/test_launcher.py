import subprocess
import sys
import time
import unittest

from support import SOURCE

sys.path.insert(0, str(SOURCE))


class LauncherTest(unittest.TestCase):
    def test_tunnel_loss_does_not_kill_the_pc_game(self):
        from run_maze4 import monitor_game

        game = subprocess.Popen([sys.executable, "-c", "import time;time.sleep(.5)"])
        tunnel = subprocess.Popen([sys.executable, "-c", "pass"])
        reported = []
        started = time.monotonic()
        try:
            result = monitor_game(game, tunnel, on_outage=lambda: reported.append(True))
            self.assertEqual(result, 0)
            self.assertGreater(time.monotonic() - started, 0.4)
            self.assertEqual(len(reported), 1)
        finally:
            for proc in (game, tunnel):
                if proc.poll() is None:
                    proc.terminate()
                proc.wait(2)


class TunnelStartupTest(unittest.TestCase):
    def test_api_error_url_is_never_published_as_game_address(self):
        from run_maze4 import QuickTunnelReady

        ready = QuickTunnelReady()
        self.assertIsNone(
            ready.feed(
                'failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": deadline exceeded'
            )
        )
        self.assertIsNone(ready.feed("INF Registered tunnel connection connIndex=0"))

    def test_banner_requires_registered_connection(self):
        from run_maze4 import QuickTunnelReady

        ready = QuickTunnelReady()
        self.assertIsNone(
            ready.feed("INF | https://four-word-game-room.trycloudflare.com |")
        )
        self.assertEqual(
            ready.feed("INF Registered tunnel connection connIndex=0"),
            "https://four-word-game-room.trycloudflare.com",
        )
