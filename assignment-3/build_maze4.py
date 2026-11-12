#!/usr/bin/env python3
"""Build only with this repository's supplied dos-tools binaries in DOSBox."""

import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SOURCES = ("MAZE4.ASM", "M4CORE.INC", "M4SER.INC", "M4UI.INC")


def environment():
    tmp = ROOT / ".scratch" / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, TMPDIR=str(tmp), TMP=str(tmp), TEMP=str(tmp))


def build():
    stage = ROOT / ".scratch" / "maze4-phone" / "build"
    stage.mkdir(parents=True, exist_ok=True)
    (stage / "TMP").mkdir(exist_ok=True)
    tools = ROOT / "dos-tools"
    for name in ("MASM.EXE", "ML.EXE", "LINK.EXE"):
        if not (tools / name).exists():
            raise RuntimeError(f"Missing supplied tool: {tools / name}")
    for name in SOURCES:
        shutil.copy2(HERE / name, stage / name)
    # MASM.EXE is the provided compatibility driver; it invokes provided ML.EXE.
    (stage / "BUILD.BAT").write_text(
        "@echo off\npath T:\\;Z:\\\nset TMP=C:\\TMP\nset TEMP=C:\\TMP\nT:\\MASM MAZE4.ASM; > BUILD.LOG\nif errorlevel 1 goto done\nT:\\LINK MAZE4.OBJ; >> BUILD.LOG\n:done\n"
    )
    conf = stage / "build.conf"
    conf.write_text(
        "[sdl]\noutput=surface\n[cpu]\ncycles=fixed 50000\n[mixer]\nnosound=true\n[midi]\nmpu401=none\n[sblaster]\nsbtype=none\n"
    )
    exe = stage / "MAZE4.EXE"
    exe.unlink(missing_ok=True)
    args = [
        "/usr/bin/dosbox",
        "-conf",
        str(conf),
        "-noautoexec",
        "-c",
        f'mount c "{stage}"',
        "-c",
        f'mount t "{tools}"',
        "-c",
        "c:",
        "-c",
        "call BUILD.BAT",
        "-c",
        "exit",
    ]
    with (stage / "dosbox.log").open("w") as log:
        subprocess.run(
            args,
            env=dict(environment(), SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"),
            stdout=log,
            stderr=log,
            timeout=30,
            check=True,
        )
    report = (stage / "BUILD.LOG").read_text(errors="replace")
    if (
        not exe.exists()
        or not exe.read_bytes().startswith(b"MZ")
        or "error " in report.lower()
    ):
        raise RuntimeError(report)
    shutil.copy2(exe, HERE / "MAZE4.EXE")
    print(report.strip())
    print(
        f"Built {HERE / 'MAZE4.EXE'} ({exe.stat().st_size} bytes) using supplied dos-tools binaries"
    )
    return HERE / "MAZE4.EXE"


if __name__ == "__main__":
    build()
