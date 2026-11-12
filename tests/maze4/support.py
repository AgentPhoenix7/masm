"""Run the supplied MASM/LINK in the installed DOSBox, with isolated mounts."""

import os
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "assignment-3"
SCRATCH = ROOT / ".scratch" / "maze4-phone"


def env():
    tmp = ROOT / ".scratch" / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, TMPDIR=str(tmp), TMP=str(tmp), TEMP=str(tmp))


def build(name="MAZE4", harness=None, directory=None, execute=True):
    stage = directory or SCRATCH / name.lower()
    stage.mkdir(parents=True, exist_ok=True)
    for p in SOURCE.glob("*.INC"):
        shutil.copy2(p, stage / p.name)
    asm = (SOURCE / "MAZE4.ASM").read_text()
    if harness:
        asm = asm.rsplit("END MAIN", 1)[0]
        (stage / "MAZE4.ASM").write_text(asm)
        (stage / f"{name}.ASM").write_text(harness)
    else:
        (stage / "MAZE4.ASM").write_text(asm)
    (stage / "TMP").mkdir(exist_ok=True)
    (stage / "BUILD.BAT").write_text(
        f"@echo off\npath T:\\;Z:\\\nset TMP=C:\\TMP\nset TEMP=C:\\TMP\nt:\\masm {name}.ASM; > BUILD.LOG\nif errorlevel 1 goto done\nt:\\link {name}.OBJ; >> BUILD.LOG\n:done\n"
    )
    conf = stage / "build.conf"
    conf.write_text(
        "[sdl]\noutput=surface\n[cpu]\ncycles=fixed 50000\n[mixer]\nnosound=true\n[midi]\nmpu401=none\n[sblaster]\nsbtype=none\n"
    )
    exe = stage / f"{name}.EXE"
    exe.unlink(missing_ok=True)
    args = [
        "/usr/bin/dosbox",
        "-conf",
        str(conf),
        "-noautoexec",
        "-c",
        f'mount c "{stage}"',
        "-c",
        f'mount t "{ROOT / "dos-tools"}"',
        "-c",
        "c:",
        "-c",
        "call BUILD.BAT",
    ]
    if harness and execute:
        args += ["-c", f"{name}.EXE"]
    args += ["-c", "exit"]
    with (stage / "dosbox.log").open("w") as log:
        subprocess.run(
            args,
            env=dict(env(), SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"),
            stdout=log,
            stderr=log,
            timeout=30,
            check=True,
        )
    text = (stage / "BUILD.LOG").read_text(errors="replace")
    if (
        not exe.exists()
        or "Severe" in text
        and "0 Severe" not in text
        or "error " in text.lower()
    ):
        raise AssertionError(text)
    return stage
