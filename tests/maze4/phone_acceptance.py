#!/usr/bin/env python3
"""Opt-in physical Android HTTPS acceptance test; ADB automates UI only.

Creates a temporary test room, three independent internet clients, and tests
phone inputs plus tunnel loss, MASM DNF handling, results, and host Esc.
Run only with a connected phone available for this task. No Wi-Fi/data setting
is changed, no browser DevTools access is used, and no ADB forwarding is used.
"""

import argparse
import http.client
import json
import os
import queue
import re
import secrets
import signal
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path
from typing import TypeVar

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / ".scratch" / "maze4-phone" / "acceptance"
TRACE = ROOT / ".scratch" / "maze4-phone" / "run" / "state.json"
sys.path.insert(0, str(ROOT / "assignment-3"))
from build_maze4 import environment

T = TypeVar("T")


def run(args, **kwargs):
    return subprocess.run(
        args, capture_output=True, check=True, env=environment(), **kwargs
    ).stdout


def wait_for(predicate: Callable[[], T | None], timeout=8) -> T:
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Acceptance condition timed out")


def state() -> dict | None:
    if not TRACE.exists() or time.time() - TRACE.stat().st_mtime > 2:
        return None
    try:
        return json.loads(TRACE.read_text())
    except ValueError:
        return None


def wait_for_state(predicate, timeout=8) -> dict:
    def matching_state():
        current = state()
        return current if current is not None and predicate(current) else None

    return wait_for(matching_state, timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--adb", default="/opt/android-sdk/platform-tools/adb")
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(environment(), SDL_VIDEODRIVER="x11")
    launcher = subprocess.Popen(
        [
            sys.executable,
            "-u",
            str(ROOT / "assignment-3/run_maze4.py"),
            "--internet",
            "--state-trace",
        ],
        cwd=ROOT,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    output = launcher.stdout
    assert output is not None, "Launcher output pipe was not created"
    lines = queue.Queue()

    def read_output():
        for line in output:
            lines.put(line.strip())

    threading.Thread(target=read_output, daemon=True).start()
    stop = threading.Event()
    clients = []
    records = []
    password = None
    origin = None

    def adb(*cmd):
        return run([args.adb, "-s", args.device, *cmd])

    def ui():
        adb("shell", "uiautomator", "dump", "/sdcard/maze4-ui.xml")
        data = adb("exec-out", "cat", "/sdcard/maze4-ui.xml")
        (OUT / "phone-ui.xml").write_bytes(data)
        return ET.fromstring(data)

    def center(node):
        a = list(map(int, re.findall(r"\d+", node.get("bounds"))))
        return (a[0] + a[2]) // 2, (a[1] + a[3]) // 2

    def tap(node):
        x, y = center(node)
        adb("shell", "input", "tap", str(x), str(y))

    def screenshot(name):
        (OUT / name).write_bytes(adb("exec-out", "screencap", "-p"))

    def pc_key(key):
        script = OUT / "focus.js"
        script.write_text(
            "for (const w of workspace.windowList()) { if (String(w.resourceClass).toLowerCase().includes('dosbox') && String(w.caption).includes('MAZE4')) { w.minimized=false; w.desktops=[workspace.currentDesktop]; workspace.activeWindow=w; } }\n"
        )
        run(
            [
                "/usr/bin/qdbus6",
                "org.kde.KWin",
                "/Scripting",
                "org.kde.kwin.Scripting.unloadScript",
                "maze4-acceptance",
            ]
        )
        run(
            [
                "/usr/bin/qdbus6",
                "org.kde.KWin",
                "/Scripting",
                "org.kde.kwin.Scripting.loadScript",
                str(script),
                "maze4-acceptance",
            ]
        )
        run(
            [
                "/usr/bin/qdbus6",
                "org.kde.KWin",
                "/Scripting",
                "org.kde.kwin.Scripting.start",
            ]
        )
        run(["/usr/bin/xdotool", "key", "--clearmodifiers", key])

    def request(path, body=None, client=None, local=False):
        assert origin is not None, "HTTPS address is not ready"
        host = origin.removeprefix("https://")
        conn = (
            http.client.HTTPConnection("127.0.0.1", 8080, timeout=6)
            if local
            else http.client.HTTPSConnection(host, timeout=8)
        )
        headers = {"Host": host, "Origin": origin, "Content-Type": "application/json"}
        if client:
            headers.update(Cookie=client["cookie"], **{"X-Maze-CSRF": client["csrf"]})
        conn.request(
            "GET" if body is None else "POST",
            path,
            None if body is None else json.dumps(body),
            headers,
        )
        response = conn.getresponse()
        data = json.loads(response.read())
        cookie = response.getheader("Set-Cookie")
        code = response.status
        conn.close()
        if code != 200:
            raise AssertionError((path, code, data))
        return data, cookie

    try:
        deadline = time.monotonic() + 50
        while not origin and time.monotonic() < deadline:
            if launcher.poll() is not None:
                raise AssertionError("Launcher exited before HTTPS startup")
            try:
                line = lines.get(timeout=0.5)
            except queue.Empty:
                continue
            if line.startswith("Room password: "):
                password = line.split()[2]
            elif line.startswith("Phone address: "):
                origin = line.split()[-1]
        assert origin and password, "HTTPS startup failed"

        def public_ready():
            assert origin is not None, "HTTPS address is not ready"
            try:
                conn = http.client.HTTPSConnection(
                    origin.removeprefix("https://"), timeout=3
                )
                conn.request("GET", "/")
                response = conn.getresponse()
                body = response.read()
                ok = response.status == 200 and b"MAZE4" in body
                conn.close()
                return ok
            except OSError:
                return False

        wait_for(public_ready, 30)
        assert not run([args.adb, "reverse", "--list"]).strip(), (
            "Remove test ADB reverse mappings first"
        )
        assert not run([args.adb, "forward", "--list"]).strip(), (
            "Remove test ADB forward mappings first"
        )
        print(
            "HTTPS room ready; no ADB forwarding. Opening only the game page.",
            flush=True,
        )
        adb("shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", origin)
        time.sleep(2)

        def game_ui():
            root = ui()
            return (
                root
                if any(
                    "Find your way out" in n.get("text", "") for n in root.iter("node")
                )
                else None
            )

        root = wait_for(game_ui, 15)
        name = next(n for n in root.iter("node") if n.get("resource-id") == "name")
        tap(name)
        adb("shell", "input", "text", "PhoneT")
        adb("shell", "input", "keyevent", "61")
        adb("shell", "input", "text", password)
        adb("shell", "input", "keyevent", "4")
        root = ui()
        tap(next(n for n in root.iter("node") if n.get("text") == "Join race"))
        time.sleep(2)
        root = ui()
        no = next((n for n in root.iter("node") if n.get("text") == "No, thanks"), None)
        if no is not None:
            tap(no)
            root = ui()
        ready = next(n for n in root.iter("node") if n.get("text") == "Ready")
        tap(ready)
        screenshot("phone-lobby.png")
        wait_for_state(
            lambda s: any(p["name"] == "PhoneT" and p["ready"] for p in s["players"])
        )
        for i in range(3):
            data, cookie = request(
                "/api/join",
                {
                    "name": f"Sim{i + 1}",
                    "password": password,
                    "attempt": secrets.token_hex(16),
                },
            )
            assert cookie is not None, "Join response did not set a session cookie"
            client = {"cookie": cookie.split(";")[0], "csrf": data["csrf"]}
            clients.append(client)
            request("/api/ready", {"ready": True}, client)

        def keepalive():
            while not stop.wait(0.7):
                for c in clients:
                    try:
                        request("/api/state", client=c)
                    except (
                        AssertionError,
                        OSError,
                        http.client.HTTPException,
                        json.JSONDecodeError,
                    ) as exc:
                        print(f"Controller heartbeat failed: {exc}", file=sys.stderr)

        threading.Thread(target=keepalive, daemon=True).start()
        wait_for_state(
            lambda s: (
                s["count"] == 4 and all(p["ready"] for p in s["players"] if p["state"])
            )
        )
        pc_key("space")
        wait_for_state(lambda s: s["phase"] == 2)
        root = ui()
        buttons = {
            n.get("content-desc"): n
            for n in root.iter("node")
            if n.get("content-desc", "").startswith("Move ")
        }
        assert len(buttons) == 4

        def player():
            current = wait_for_state(
                lambda s: any(p["name"] == "PhoneT" for p in s["players"])
            )
            return next(p.copy() for p in current["players"] if p["name"] == "PhoneT")

        for desc in ("Move left", "Move right", "Move up", "Move down"):
            before = player()
            tap(buttons[desc])
            time.sleep(0.9)
            after = player()
            assert after["steps"] - before["steps"] in (0, 1), "A quick tap repeated"
            records.append(
                {"action": "tap", "direction": desc, "before": before, "after": after}
            )
            print(
                f"Phone tap {desc}: {before['pos']} -> {after['pos']}, steps +{after['steps'] - before['steps']}",
                flush=True,
            )
        for desc in ("Move down", "Move up", "Move left", "Move right"):
            before = player()
            x, y = center(buttons[desc])
            adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), "1100")
            time.sleep(0.8)
            after = player()
            time.sleep(0.9)
            released = player()
            assert released["steps"] == after["steps"], (
                "Held movement continued after release"
            )
            records.append(
                {
                    "action": "hold1100ms",
                    "direction": desc,
                    "before": before,
                    "after": after,
                    "released": released,
                }
            )
            print(
                f"Phone hold {desc}: steps +{after['steps'] - before['steps']}; stopped after release",
                flush=True,
            )
        assert any(r["after"]["steps"] > r["before"]["steps"] for r in records)
        assert any(r["after"]["steps"] == r["before"]["steps"] for r in records)
        current = wait_for_state(lambda s: s["phase"] == 2)
        assert all(
            p["steps"] == 0 for p in current["players"] if p["name"].startswith("Sim")
        )
        screenshot("phone-racing.png")
        run(
            [
                "/usr/bin/spectacle",
                "-a",
                "-b",
                "-n",
                "-o",
                str(OUT / "dosbox-racing.png"),
            ]
        )
        (OUT / "movement.json").write_text(json.dumps(records, indent=2))
        current = wait_for_state(lambda s: s["phase"] == 2)
        active = [p["id"] for p in current["players"] if p["state"] == 1]
        # Kill only the cloudflared child of the launcher owned by this test.
        children = (
            Path(f"/proc/{launcher.pid}/task/{launcher.pid}/children")
            .read_text()
            .split()
        )
        tunnels = [
            int(pid)
            for pid in children
            if b"cloudflared" in Path(f"/proc/{pid}/cmdline").read_bytes()
        ]
        assert len(tunnels) == 1, "Expected exactly one owned tunnel child"
        os.kill(tunnels[0], signal.SIGTERM)
        stop.set()
        print(
            "Stopped owned tunnel; checking that the real PC game stays open and MASM reaches DNF.",
            flush=True,
        )
        time.sleep(2)
        assert launcher.poll() is None, "Tunnel loss closed DOSBox"
        final = wait_for_state(
            lambda s: all(s["players"][i]["state"] == 3 for i in active), 36
        )
        assert final["phase"] == 3
        data, _ = request("/api/state", client=clients[0], local=True)
        assert data["player"]["state"] == 3, (
            "DNF terminal state not available to authenticated player"
        )
        pc_key("Tab")
        time.sleep(0.3)
        run(
            [
                "/usr/bin/spectacle",
                "-a",
                "-b",
                "-n",
                "-o",
                str(OUT / "dosbox-results.png"),
            ]
        )
        (OUT / "results.json").write_text(json.dumps(final, indent=2))
        pc_key("Escape")
        launcher.wait(6)
        assert launcher.returncode == 0, "Host Esc did not exit cleanly"
        (OUT / "summary.json").write_text(
            json.dumps(
                {
                    "phone": args.device,
                    "transport": "public HTTPS",
                    "players": 4,
                    "adb_forwarding": False,
                    "quick_taps_exact": True,
                    "hold_release": True,
                    "independent_players": True,
                    "tunnel_loss_keeps_pc": True,
                    "masm_dnf_results": True,
                    "authenticated_dnf_readable": True,
                    "host_escape": True,
                    "separate_network_test": False,
                },
                indent=2,
            )
        )
        print(
            "PASS: final real phone HTTPS movement, four independent controllers, tunnel loss, MASM DNF/results, authenticated DNF and host Esc.",
            flush=True,
        )
    finally:
        stop.set()
        if launcher.poll() is None:
            launcher.terminate()
            try:
                launcher.wait(8)
            except subprocess.TimeoutExpired:
                launcher.kill()
                launcher.wait(2)
        try:
            run(
                [
                    "/usr/bin/qdbus6",
                    "org.kde.KWin",
                    "/Scripting",
                    "org.kde.kwin.Scripting.unloadScript",
                    "maze4-acceptance",
                ]
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            print(f"Could not unload acceptance focus helper: {exc}", file=sys.stderr)
        # Only the temporary UI dump created by this test is removed from phone.
        try:
            adb("shell", "rm", "-f", "/sdcard/maze4-ui.xml")
        except (OSError, subprocess.CalledProcessError) as exc:
            print(f"Could not remove acceptance UI dump: {exc}", file=sys.stderr)


if __name__ == "__main__":
    main()
