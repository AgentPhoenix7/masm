import struct
import subprocess
import sys
import unittest

from support import ROOT, build, env

sys.path.insert(0, str(ROOT / "assignment-3" / "phone"))
from protocol import SerialLink, TransportError


class RuntimeTest(unittest.TestCase):
    def test_actual_dosbox_com1(self):
        stage = build()
        link = SerialLink(0)
        conf = stage / "serial.conf"
        conf.write_text(
            f"[sdl]\noutput=surface\n[cpu]\ncycles=fixed 50000\n[mixer]\nnosound=true\n[midi]\nmpu401=none\n[sblaster]\nsbtype=none\n[serial]\nserial1=nullmodem server:127.0.0.1 port:{link.port} transparent:1 rxdelay:1000\n"
        )
        log = (stage / "runtime.log").open("w")
        proc = subprocess.Popen(
            [
                "/usr/bin/dosbox",
                "-conf",
                str(conf),
                "-noautoexec",
                "-c",
                f'mount c "{stage}"',
                "-c",
                "c:",
                "-c",
                "MAZE4.EXE",
                "-c",
                "exit",
            ],
            env=dict(env(), SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"),
            stdout=log,
            stderr=log,
        )
        try:
            state = link.wait_for(lambda s: s["capacity"] >= 2, 5)
            print("COM1 state:", {k: v for k, v in state.items() if k != "players"})
            epoch = state["epoch"]
            self.assertEqual(link.request(1, epoch, b"ABCDEFGH2345")[0], 0)
            owners = []
            for n in range(state["capacity"]):
                code, slot, owner = link.request(
                    2, epoch, f"Player{n + 1}".ljust(8).encode()
                )
                self.assertEqual(code, 0)
                self.assertEqual(slot, n)
                owners.append(owner)
            self.assertEqual(link.request(2, epoch, b"Overflow")[0], 2)
            self.assertEqual(
                link.request(2, epoch, b"Player1 ", request_id=owners[0])[:2], (0, 0)
            )
            state = link.wait_for(lambda s: s["count"] == s["capacity"])
            self.assertEqual(len({p["pos"] for p in state["players"]}), 8)
            for i, owner in enumerate(owners):
                self.assertEqual(
                    link.request(6, epoch, struct.pack("<BHB", i, owner, 1))[0], 0
                )
            self.assertEqual(link.request(4, epoch, struct.pack("<BH", 0, 65535))[0], 3)
            with self.assertRaises(TransportError):
                link.request(4, epoch + 1, struct.pack("<BH", 0, owners[0]))
            self.assertEqual(
                link.request(5, epoch, struct.pack("<BH", 0, owners[0]))[0], 0
            )
            link.wait_for(lambda s: s["players"][0]["state"] == 0)
            self.assertEqual(
                link.request(4, epoch, struct.pack("<BH", 0, owners[0]))[0], 3
            )
        finally:
            proc.terminate()
            proc.wait(5)
            log.close()
            link.close()


if __name__ == "__main__":
    unittest.main()
