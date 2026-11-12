#!/usr/bin/env python3
"""Start the MASM game, authenticated controller bridge and optional HTTPS tunnel."""

import argparse
import json
import re
import signal
import subprocess
import sys
import threading
import time
from contextlib import ExitStack
from pathlib import Path

from build_maze4 import SOURCES, build, environment
from phone.bridge import App, ControllerServer
from phone.protocol import SerialLink, TransportError

HERE = Path(__file__).resolve().parent


class QuickTunnelReady:
    """Only the allocated banner URL, after an actual registered connection."""

    def __init__(self):
        self.candidate = None
        self.connected = False

    def feed(self, line):
        match = re.search(
            r"\|\s*(https://(?!api\.|www\.)[a-z0-9-]+\.trycloudflare\.com)\s*\|", line
        )
        if match:
            self.candidate = match.group(1)
        if "Registered tunnel connection" in line:
            self.connected = True
        return self.candidate if self.connected else None


def monitor_game(game, tunnel=None, *, on_outage=lambda: None, on_tick=None):
    reported = False
    while game.poll() is None:
        if tunnel is not None and tunnel.poll() is not None and not reported:
            on_outage()
            reported = True
        if on_tick:
            on_tick()
        time.sleep(0.2)
    return game.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--internet",
        action="store_true",
        help="Start an authenticated temporary public HTTPS tunnel",
    )
    mode.add_argument(
        "--origin", help="Existing HTTPS reverse proxy origin pointing at the HTTP port"
    )
    mode.add_argument(
        "--local-test",
        action="store_true",
        help="Explicit localhost-only HTTP test mode; never combine with a public tunnel",
    )
    parser.add_argument("--http-port", type=int, default=8080)
    parser.add_argument("--serial-port", type=int, default=8766)
    parser.add_argument(
        "--headless",
        action="store_true",
        help="DOSBox dummy display, for automated tests",
    )
    parser.add_argument("--rebuild", action="store_true")
    parser.add_argument(
        "--state-trace",
        action="store_true",
        help="Save credential-free MASM state under project scratch for testing",
    )
    args = parser.parse_args()
    scratch = HERE.parent / ".scratch" / "maze4-phone" / "run"
    scratch.mkdir(parents=True, exist_ok=True)
    exe = HERE / "MAZE4.EXE"
    if (
        args.rebuild
        or not exe.exists()
        or any((HERE / name).stat().st_mtime > exe.stat().st_mtime for name in SOURCES)
    ):
        build()

    def stop_process(proc):
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(2)

    def interrupt(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt)
    with ExitStack() as stack:
        link = SerialLink(args.serial_port)
        stack.callback(link.close)
        origin = (
            f"http://127.0.0.1:{args.http_port}" if args.local_test else args.origin
        )
        app = App(link, origin, local_test=args.local_test)
        stack.callback(app.close)
        server = ControllerServer(args.http_port, app)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        stack.callback(server.server_close)
        stack.callback(server.shutdown)
        log = stack.enter_context((scratch / "dosbox.log").open("w"))
        conf = scratch / "phone.conf"
        text = (
            (HERE / "PHONE4.CONF").read_text().replace("port:8766", f"port:{link.port}")
        )
        if args.headless:
            text = text.replace("output=openglnb", "output=surface")
        conf.write_text(text)
        dosenv = environment()
        if args.headless:
            dosenv.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
        proc = subprocess.Popen(
            [
                "/usr/bin/dosbox",
                "-conf",
                str(conf),
                "-noautoexec",
                "-c",
                f'mount c "{HERE}"',
                "-c",
                "c:",
                "-c",
                "MAZE4.EXE",
                "-c",
                "exit",
            ],
            env=dosenv,
            stdout=log,
            stderr=log,
        )
        stack.callback(stop_process, proc)
        link.wait_for(lambda s: s["capacity"] >= 2, 10)
        app.sync_room()
        app.start()
        tunnel = None
        if args.internet:
            empty = scratch / "empty-cloudflared.yml"
            empty.write_text("{}\n")
            tunnel_log = stack.enter_context((scratch / "tunnel.log").open("w"))
            tunnel = subprocess.Popen(
                [
                    "/usr/bin/cloudflared",
                    "tunnel",
                    "--config",
                    str(empty),
                    "--no-autoupdate",
                    "--url",
                    f"http://127.0.0.1:{args.http_port}",
                ],
                env=environment(),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            stack.callback(stop_process, tunnel)
            tunnel_output = tunnel.stdout
            if tunnel_output is None:
                raise RuntimeError("HTTPS tunnel output is unavailable")
            found = threading.Event()
            readiness = QuickTunnelReady()

            def read_tunnel():
                for line in tunnel_output:
                    tunnel_log.write(line)
                    tunnel_log.flush()
                    public_origin = readiness.feed(line)
                    if public_origin and not found.is_set():
                        app.set_origin(public_origin)
                        found.set()
                if not found.is_set():
                    found.set()

            threading.Thread(target=read_tunnel, daemon=True).start()
            deadline = time.monotonic() + 40
            while not found.wait(0.2) and time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise RuntimeError("DOSBox exited before tunnel startup")
            if app.origin is None:
                raise RuntimeError(
                    f"HTTPS tunnel did not start; see {scratch / 'tunnel.log'}"
                )
        print(f"Phone address: {app.origin}", flush=True)
        print(
            "Phones enter the room password. Host: Space=start, M=mode, R=new maze, N=new room, 1–8=remove, Tab=scores, Esc=quit.",
            flush=True,
        )
        print(
            "ADB is not used for game traffic. Ctrl+C stops this launcher and its own processes.",
            flush=True,
        )

        def trace_state():
            if not args.state_trace:
                return
            try:
                current = link.latest()
                trace = {k: v for k, v in current.items() if k != "players"}
                trace["players"] = [
                    {k: v for k, v in p.items() if k != "owner"}
                    for p in current["players"]
                ]
                target = scratch / "state.json"
                temporary = scratch / "state.new"
                temporary.write_text(json.dumps(trace, indent=2))
                temporary.replace(target)
            except TransportError:
                pass

        def tunnel_outage():
            print(
                "HTTPS tunnel stopped. The PC race continues; MASM expires inputs and handles disconnects. Use Esc or Ctrl+C to quit.",
                flush=True,
            )

        return monitor_game(proc, tunnel, on_outage=tunnel_outage, on_tick=trace_state)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped MAZE4.")
    except (RuntimeError, OSError, TransportError, ValueError) as exc:
        print(f"MAZE4: {exc}", file=sys.stderr)
        sys.exit(1)
