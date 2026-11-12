"""Real HTTP -> authentication -> TCP COM1 -> actual 8086 MASM integration."""

import http.client
import json
import secrets
import struct
import subprocess
import sys
import threading
import time
import unittest

from support import ROOT, build, env

sys.path.insert(0, str(ROOT / "assignment-3" / "phone"))
from bridge import App, ControllerServer
from protocol import SerialLink

# Controlled open board makes movement expectations independent of generation.
# The generator itself is exercised separately against an independent BFS oracle.
HARNESS = """M4_TEST EQU 1
INCLUDE MAZE4.ASM
INCLUDE M4SER.INC
.CODE
TEST_MAIN PROC
MOV AX,@DATA
MOV DS,AX
MOV ES,AX
CLD
MOV AH,0
INT 1AH
MOV WORD PTR LAST_BIOS,DX
MOV WORD PTR LAST_BIOS+2,CX
CALL GENERATE_MAZE
LEA DI,MAZE
MOV CX,CELLS
MOV AL,'#'
REP STOSB
MOV BP,15
LEA DI,MAZE+62
TEST_FILL:
MOV CX,59
MOV AL,' '
REP STOSB
ADD DI,2
DEC BP
JNZ TEST_FILL
MOV EXIT_POS,650
MOV MAZE[650],'E'
MOV STARTS[0],315
MOV STARTS[2],317
MOV CAPACITY,8
CALL SERIAL_INIT
TEST_LOOP:
CALL READ_CLOCK
CALL SERIAL_POLL
CALL START_RACE
CALL GAME_TICK
MOV AX,SYSTEM_TICK
SUB AX,STATE_TICK
CMP AX,4
JB TEST_FLUSH
MOV AX,SYSTEM_TICK
MOV STATE_TICK,AX
CALL SEND_STATE
TEST_FLUSH:
CALL SERIAL_FLUSH
MOV AX,TX_HEAD
CMP AX,TX_TAIL
JNE TEST_LOOP
STI
HLT
JMP TEST_LOOP
TEST_MAIN ENDP
END TEST_MAIN
"""


class EndToEndTest(unittest.TestCase):
    def test_auth_to_actual_assembly_movement(self):
        stage = build("E2EGAME", HARNESS, execute=False)
        link = SerialLink(0)
        app = None
        server = None
        proc = None
        log = None
        try:
            conf = stage / "runtime.conf"
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
                    "E2EGAME.EXE",
                    "-c",
                    "exit",
                ],
                env=dict(env(), SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"),
                stdout=log,
                stderr=log,
            )
            link.wait_for(lambda s: s["capacity"] == 8, 5)
            app = App(link, local_test=True)
            app.sync_room()
            app.start()
            server = ControllerServer(0, app)
            port = server.server_port
            origin = f"http://127.0.0.1:{port}"
            app.set_origin(origin)
            threading.Thread(target=server.serve_forever, daemon=True).start()

            def request(path, body=None, client=None):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                headers = {"Origin": origin, "Content-Type": "application/json"}
                if client:
                    headers.update(
                        Cookie=client["cookie"], **{"X-Maze-CSRF": client["csrf"]}
                    )
                conn.request(
                    "GET" if body is None else "POST",
                    path,
                    None if body is None else json.dumps(body),
                    headers,
                )
                response = conn.getresponse()
                data = json.loads(response.read())
                cookie = response.getheader("Set-Cookie")
                status = response.status
                conn.close()
                return status, data, cookie

            clients = []
            for name in ("Alice", "Bob"):
                status, data, cookie = request(
                    "/api/join",
                    {
                        "password": app.password,
                        "name": name,
                        "attempt": secrets.token_hex(16),
                    },
                )
                self.assertEqual(status, 200, data)
                assert cookie is not None, "Join response did not set a session cookie"
                c = {"cookie": cookie.split(";")[0], "csrf": data["csrf"]}
                clients.append(c)
                self.assertEqual(request("/api/ready", {"ready": True}, c)[0], 200)
            link.wait_for(lambda s: s["phase"] == 2)
            self.assertEqual(
                request(
                    "/api/input",
                    {"seq": 1, "direction": 3, "tap": True, "player": 1},
                    clients[0],
                )[0],
                200,
            )
            self.assertEqual(
                request(
                    "/api/input", {"seq": 2, "direction": 0, "tap": False}, clients[0]
                )[0],
                200,
            )
            state = link.wait_for(lambda s: s["players"][0]["steps"] >= 1)
            self.assertEqual(state["players"][0]["pos"], 314)
            time.sleep(0.5)
            self.assertEqual(link.latest()["players"][0]["steps"], 1)
            self.assertEqual(link.latest()["players"][1]["pos"], 317)
            self.assertEqual(
                request(
                    "/api/input", {"seq": 3, "direction": 3, "tap": False}, clients[0]
                )[0],
                200,
            )
            time.sleep(1.1)
            after = link.latest()["players"][0]
            self.assertGreater(after["steps"], 1)
            self.assertGreater(
                after["pos"], 306
            )  # stopped by lease before reaching wall
            time.sleep(0.5)
            self.assertEqual(link.latest()["players"][0]["steps"], after["steps"])
            self.assertEqual(
                request(
                    "/api/input", {"seq": 2, "direction": 4, "tap": False}, clients[0]
                )[0],
                409,
            )
            self.assertEqual(
                request(
                    "/api/join",
                    {
                        "password": app.password,
                        "name": "Late",
                        "attempt": secrets.token_hex(16),
                    },
                )[0],
                409,
            )
            # Parser must recover after bad hex, corrupt checksum and oversized frame.
            with link.request_lock:
                connection = link.connection
                assert connection is not None, "DOSBox serial connection was lost"
                connection.sendall(b":ZZ\n:010000\n:" + b"00" * 150 + b"\n")
            state = link.latest()
            owner = state["players"][0]["owner"]
            self.assertEqual(
                link.request(4, state["epoch"], struct.pack("<BH", 0, owner))[0], 0
            )
            print(
                "PASS: real HTTP auth -> MASM COM1 tap, ownership, lease, late join, stale sequence and malformed-frame recovery"
            )
        finally:
            if proc is not None:
                proc.terminate()
                proc.wait(5)
            if server is not None:
                server.shutdown()
                server.server_close()
            if app is not None:
                app.close()
            link.close()
            if log is not None:
                log.close()


if __name__ == "__main__":
    unittest.main()
