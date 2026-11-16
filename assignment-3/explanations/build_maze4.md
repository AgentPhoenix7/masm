# build_maze4.py — turning the MAZE4 source into a DOS executable

Source: [build_maze4.py](../build_maze4.py).

This guide explains the complete Python file from its first line to its entry point. It
assumes basic Python and the registers, memory, subroutines, and assembler ideas familiar
from 8085 work. No earlier maze program is required.

The program being built is an 8086 DOS game. Its assembly entry file is
[MAZE4.ASM](../MAZE4.ASM), explained in [MAZE4.md](MAZE4.md). The builder prepares files and
runs tools; it does not implement movement, scoring, phone authentication, or the game's
communication protocol.

For the later process-launching stage, use [run_maze4.md](run_maze4.md). This page is a
source walkthrough, not an installation guide or a record of a fresh build. The example
execution traces below are illustrative.

## 1. The builder's complete job

The intended transformation is:

```text
MAZE4.ASM + M4CORE.INC + M4SER.INC + M4UI.INC
    → stage source copies in project scratch
    → DOSBox runs the supplied assembler
    → assembler produces MAZE4.OBJ
    → DOSBox runs the supplied linker
    → linker produces staged MAZE4.EXE
    → Python checks the result and copies it to assignment-3/MAZE4.EXE
```

An assembler translates assembly source into an object file. A linker turns the object file
into the executable DOS will load. The `.INC` files are inserted while assembling
`MAZE4.ASM`; they are not independent Python modules or separate programs that this builder
launches.

The Python code runs on the host Linux system. The DOS tools run inside DOSBox. Keeping
those two environments separate explains most of the path handling.

## 2. The first two lines describe how to invoke and understand the file

```python
#!/usr/bin/env python3
"""Build only with this repository's supplied dos-tools binaries in DOSBox."""
```

The first line is a shebang. When the operating system executes this file directly,
`/usr/bin/env` finds `python3` through the host's executable search path. When an existing
Python interpreter loads the file, the shebang is a comment.

The quoted string is the module docstring. It describes the builder's policy: use this
repository's tools through DOSBox. The string does not itself perform a check or launch any
program. The later `tools` path and subprocess argument list implement that policy.

## 3. Each import has one small responsibility

```python
import os
import shutil
import subprocess
from pathlib import Path
```

| Import | Use in this file |
| --- | --- |
| `os` | Read the current host environment through `os.environ` |
| `shutil` | Copy source files and the resulting executable with `copy2` |
| `subprocess` | Start DOSBox and wait for it to finish |
| `Path` | Construct paths, make directories, and read/write files |

These are Python standard-library modules. `from pathlib import Path` makes the class name
available as `Path`, so the rest of the file need not spell it `pathlib.Path`.

There is no import of a game engine, assembler library, or web framework. Python delegates
assembly and linking to external executable files.

## 4. `HERE` starts from the script's location

```python
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
SOURCES = ("MAZE4.ASM", "M4CORE.INC", "M4SER.INC", "M4UI.INC")
```

`__file__` identifies the loaded Python file. `Path(__file__)` wraps that name in a path
object. `resolve()` produces an absolute path, resolving symbolic links and removing
components such as `..`; `.parent` then selects the containing directory. These are the
documented [`Path.resolve()`
semantics](https://docs.python.org/3/library/pathlib.html#pathlib.Path.resolve).

For the normal repository layout:

```text
ROOT                         masm/
HERE                         masm/assignment-3/
Path(__file__).resolve()      masm/assignment-3/build_maze4.py
```

The displayed paths are shortened for readability. At runtime, these `Path` values are
absolute. Changing the terminal's working directory does not change where `HERE` points.
Following a symlink to the script can resolve to the real script's directory.

`ROOT` is a layout assumption: the parent of `assignment-3` is the repository root. The
script does not run Git to discover the root.

## 5. `SOURCES` is the explicit set of assembly inputs

`SOURCES` is a tuple containing four strings. A tuple is a fixed ordered collection; the
following loop visits each name.

```text
MAZE4.ASM       main assembly unit, constants, shared data, INCLUDE directives
M4CORE.INC     maze and game algorithms
M4SER.INC      serial communication and race lifecycle
M4UI.INC       entry point, host controls, and display
```

Only those four source files are copied by this builder. Phone HTML, JavaScript, CSS, and
Python bridge files are not inputs to MASM. They remain separate files used when the
complete system runs.

An include filename being in this tuple does not assemble it separately. The DOS batch file
still invokes MASM only once, on `MAZE4.ASM`. For the include contents, see
[M4CORE.md](M4CORE.md), [M4SER.md](M4SER.md), and [M4UI.md](M4UI.md).

## 6. `environment()` prepares host-side temporary storage

```python
def environment():
    tmp = ROOT / ".scratch" / "tmp"
    tmp.mkdir(parents=True, exist_ok=True)
    return dict(os.environ, TMPDIR=str(tmp), TMP=str(tmp), TEMP=str(tmp))
```

`def` defines a function; its indented body runs only when someone calls it. The `/`
operator joins `Path` components here. It is not numeric division because the left operand
is a path object.

`tmp` therefore points to `masm/.scratch/tmp`. `parents=True` allows creation of missing
parent directories. `exist_ok=True` permits an existing directory at that path. It does not
make an existing ordinary file usable as a directory. See the official [`Path.mkdir()`
documentation](https://docs.python.org/3/library/pathlib.html#pathlib.Path.mkdir).

The function returns an environment dictionary after ensuring that directory exists. It does
not return the directory itself and does not change directory.

## 7. A copied environment is different from changing the parent process

Focus on the return expression:

```python
dict(os.environ, TMPDIR=str(tmp), TMP=str(tmp), TEMP=str(tmp))
```

`os.environ` is the host process's environment mapping. `dict(...)` builds a new dictionary
containing its current entries. The named arguments then set or replace three entries in
that new dictionary. `str(tmp)` supplies a string path, as environment values require
strings here.

For example, an inherited `PATH` is retained, while a previously different `TMPDIR` is
replaced in the returned mapping. The original `os.environ` is not assigned to or updated by
this expression. The parent Python process's temporary-directory variables therefore remain
unchanged.

Later, `env=...` gives this mapping to one child process. When explicitly supplied, `env`
replaces that child's automatic environment inheritance; copying `os.environ` first
preserves the other inherited values. See [`subprocess` environment
handling](https://docs.python.org/3/library/subprocess.html#subprocess.Popen).

The launcher also imports this helper, but importing it does not call it. The launcher guide
explains its other calls separately.

## 8. `build()` creates a fixed staging directory

```python
def build():
    stage = ROOT / ".scratch" / "maze4-phone" / "build"
    stage.mkdir(parents=True, exist_ok=True)
    (stage / "TMP").mkdir(exist_ok=True)
```

`stage` is where copied sources, DOS batch/config files, and tool outputs live. The second
`mkdir` creates a `TMP` subdirectory inside that stage. It needs no `parents=True` because
the preceding statement creates `stage`.

The two temporary directories have different users:

| Host path | Purpose |
| --- | --- |
| `masm/.scratch/tmp` | Temporary-directory variables passed to host processes |
| `masm/.scratch/maze4-phone/build/TMP` | Directory exposed to DOS tools as `C:\TMP` |

The uppercase directory name matches the DOS batch file's spelling. The builder reuses this
same stage on later calls. It does not create a fresh random directory for each invocation.

## 9. Tool checks happen before source copying

```python
tools = ROOT / "dos-tools"
for name in ("MASM.EXE", "ML.EXE", "LINK.EXE"):
    if not (tools / name).exists():
        raise RuntimeError(f"Missing supplied tool: {tools / name}")
```

The loop constructs a path for each required tool and checks existence. The `f` prefix
allows `{tools / name}` to be evaluated inside the message. `raise` stops normal execution
and passes an exception to the caller. This function contains no surrounding handler to
recover from that exception.

Existence is a preliminary check. It does not prove that the path is a usable file, that its
contents are intact, or that every auxiliary dependency of the DOS tools is present. For
example, the loop does not separately check every file in `dos-tools`.

The repository's supplied [packing list](../../dos-tools/DISK1/PACKING.TXT) describes
`MASM.EXE` as the 5.1-compatible command-line driver and `ML.EXE` as the assembler
executable. The supplied [release notes](../../dos-tools/DISK1/README.TXT) explain that the
compatibility driver converts the old command-line form and invokes ML. Those source
documents explain why both executables are required.

## 10. Source files are copied; tool files are mounted

```python
for name in SOURCES:
    shutil.copy2(HERE / name, stage / name)
# MASM.EXE is the provided compatibility driver; it invokes provided ML.EXE.
```

`HERE / name` is the original assembly source. `stage / name` is its staged copy with the
same filename. `copy2` copies file contents and attempts to preserve metadata such as times
and permission information; it does not promise identical metadata on every platform. See
[`shutil.copy2()`](https://docs.python.org/3/library/shutil.html#shutil.copy2).

An existing destination file is replaced. The source remains in `assignment-3`, so generated
object and executable files can be kept away from the original source during assembly. If a
source is absent or unreadable, the copy raises an exception.

No loop copies `MASM.EXE`, `ML.EXE`, or `LINK.EXE` into the stage. DOSBox will expose the
existing `dos-tools` directory as a separate drive. The explicit `T:\MASM` and `T:\LINK`
commands then select those supplied tools.

## 11. Python writes a DOS batch file

The next source statement writes `stage / "BUILD.BAT"` using `write_text`. The generated
contents, with Python's escaped backslashes decoded, are exactly:

```bat
@echo off
path T:\;Z:\
set TMP=C:\TMP
set TEMP=C:\TMP
T:\MASM MAZE4.ASM; > BUILD.LOG
if errorlevel 1 goto done
T:\LINK MAZE4.OBJ; >> BUILD.LOG
:done
```

The source string uses `\n` for line breaks and `\\` for one literal backslash. Those escape
sequences belong to Python's string syntax. DOS sees the resulting batch text above, not the
Python escape notation.

`write_text` opens the destination, writes the text, and closes it. It replaces previous
contents of `BUILD.BAT`. The source does not specify an encoding; the written text uses
ASCII characters, which avoids non-ASCII names within the generated batch content.

## 12. The batch header prepares the DOS environment

`@echo off` suppresses the routine echoing of batch commands. The initial `@` also
suppresses echoing that particular command. It does not silence the assembler's own
messages.

`path T:\;Z:\` sets the DOS executable search path to the supplied-tool drive and DOSBox's
internal drive. Here the semicolon separates two search-path entries. It is not an
assembly-language comment marker in this batch command.

The next two lines set DOS environment variables:

```bat
set TMP=C:\TMP
set TEMP=C:\TMP
```

These refer to a path inside the emulated DOS environment. They do not refer to the host's
`/tmp` directory or to the host string in `TMPDIR` returned by `environment()`. After
mounting, `C:\TMP` corresponds to the stage's `TMP` subdirectory.

## 13. The assembler command has two kinds of punctuation

```bat
T:\MASM MAZE4.ASM; > BUILD.LOG
```

`T:\MASM` selects the assembler compatibility driver on the mounted tool drive. `MAZE4.ASM`
is found in the current DOS directory, which will be `C:\`. The staged include files are
there alongside it.

The trailing semicolon belongs to the tools' old-style command-line syntax: it accepts
defaults for remaining filename prompts instead of waiting for interactive answers. It is
not a comment starting after `MAZE4.ASM`, and it is not a Linux shell command separator in
this file. The supplied release notes also discuss terminating MASM command lines with a
semicolon when describing the compatibility interface.

`>` is DOS output redirection. It creates or truncates `BUILD.LOG` and writes the command's
standard output there. The batch file does not explicitly redirect the command's standard
error with a separate `2>` operation.

## 14. `errorlevel` decides whether linking is attempted

```bat
if errorlevel 1 goto done
T:\LINK MAZE4.OBJ; >> BUILD.LOG
:done
```

In this DOS condition, `if errorlevel 1` means an exit status of at least 1. It does not
mean only an exit status exactly equal to 1. After a reported assembly failure, control
jumps to the `:done` label. The linker command is skipped.

Otherwise the linker reads `MAZE4.OBJ` from the stage. Its trailing semicolon again supplies
remaining defaults. `>>` appends output, preserving the assembler messages already in
`BUILD.LOG`.

`:done` is a batch label, not a Python label or an 8086 machine instruction. There is no
second explicit `if errorlevel` after LINK. There is also no explicit propagation of a
tool's failure status to the host Python process. Python therefore examines the output file
and report later.

## 15. The generated DOSBox configuration is for building

```python
conf = stage / "build.conf"
conf.write_text(
    "[sdl]\noutput=surface\n[cpu]\ncycles=fixed 50000\n[mixer]\nnosound=true\n[midi]\nmpu401=none\n[sblaster]\nsbtype=none\n"
)
```

Expanded, the configuration is:

```ini
[sdl]
output=surface
[cpu]
cycles=fixed 50000
[mixer]
nosound=true
[midi]
mpu401=none
[sblaster]
sbtype=none
```

It selects surface output, a fixed emulation cycle setting, and disabled audio features.
`50000` is a DOSBox emulation setting, not an 8086 instruction count that the Python program
measures and not a game movement timer.

This file has no COM1 configuration or phone transport setup. It is separate from the
configuration used to run the actual game. The builder's DOSBox session runs the tools and
then exits.

## 16. Delete the staged executable before attempting a new build

```python
exe = stage / "MAZE4.EXE"
exe.unlink(missing_ok=True)
```

`exe` names the prospective staged output. `unlink` removes that file; `missing_ok=True`
allows it to be absent. Other removal errors can still raise exceptions. See
[`Path.unlink()`](https://docs.python.org/3/library/pathlib.html#pathlib.Path.unlink).

This prevents an old staged executable from satisfying the later existence and `MZ` checks
after a build produces no new executable. It removes only `stage/MAZE4.EXE`, not
`assignment-3/MAZE4.EXE`. An already published executable remains until a later copy
replaces it.

The statement occurs after the tool checks and source/config preparation. A failure before
this point may leave an old staged executable untouched. The code also does not remove an
old `.OBJ`, `.MAP`, or `BUILD.LOG` beforehand. Its stale-output protection is deliberately
limited to this one staged EXE.

## 17. The subprocess arguments are a Python list

```python
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
```

Each list element is one host process argument. The executable path is explicitly
`/usr/bin/dosbox`; host `PATH` is not used to choose a different DOSBox binary. `str(conf)`
converts a path object into the string passed after `-conf`.

`-noautoexec` excludes the configuration's automatic startup commands. The repeated `-c`
arguments provide the DOS commands for this invocation. The source does not pass a `cwd`
argument to `subprocess.run`. The absolute host paths and explicit DOS drive selection
determine the relevant locations instead.

## 18. Mounting connects the two filename systems

The commands execute in this order:

| DOSBox command | Effect |
| --- | --- |
| `mount c ".../build"` | Expose the stage as DOS drive C |
| `mount t ".../dos-tools"` | Expose supplied tools as DOS drive T |
| `c:` | Select drive C, initially its root directory here |
| `call BUILD.BAT` | Run the generated batch file |
| `exit` | Close this DOSBox session after the batch returns |

Consequently, DOS `C:\MAZE4.ASM` and the host's staged `MAZE4.ASM` refer to the same file
through different path systems. The original `assignment-3/MAZE4.ASM` is a separate copied
source file.

The quotes around mount paths are literal characters inside each DOSBox command string. They
allow DOSBox's command parser to handle spaces in paths. They are not shell quoting
performed by Bash. Because `shell` is omitted, Python uses the default `shell=False` and
launches the argument list without a host command-shell interpretation. See
[`subprocess.run()`](https://docs.python.org/3/library/subprocess.html#subprocess.run).

## 19. The DOSBox log is opened before launching the process

```python
with (stage / "dosbox.log").open("w") as log:
    subprocess.run(
        args,
        env=dict(environment(), SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy"),
        stdout=log,
        stderr=log,
        timeout=30,
        check=True,
    )
```

`open("w")` creates or truncates the host-side DOSBox log. `as log` gives the open file
object a name. The `with` statement closes it when this block ends, including when an
exception leaves the block.

Both DOSBox standard output and standard error go to this file. They are not captured into a
Python string and are not printed live by this code. The returned `CompletedProcess` object
is not assigned to a variable.

`dosbox.log` and `BUILD.LOG` have different producers. The former records host-process
diagnostics; the latter comes from DOS batch redirection of assembler/linker output.

## 20. Dummy SDL drivers apply to the build subprocess

The nested environment expression first calls `environment()`. It then constructs another
dictionary adding or replacing:

```text
SDL_VIDEODRIVER = dummy
SDL_AUDIODRIVER = dummy
```

These settings request dummy SDL video and audio drivers for the DOSBox child. They make
this build session suitable for running without an interactive display or sound output when
supported by the installed DOSBox/SDL setup. The code does not open the game's normal
visible window.

The parent process still has its original environment. An interactive game process launched
later has whatever environment its own launcher supplies; these two dictionary entries do
not globally persist.

There are therefore two explicit layers of temporary configuration: host environment strings
passed to DOSBox, and DOS `set TMP`/`set TEMP` commands executed inside its emulated
session.

## 21. Process completion has two separate failure conditions

`subprocess.run` waits for the DOSBox process to finish. `timeout=30` sets a 30-second
waiting limit for this call's process operation. On timeout, Python terminates the child as
documented and raises `subprocess.TimeoutExpired`; process creation can itself delay how
soon the timeout is observed on some platforms.

`check=True` raises `subprocess.CalledProcessError` when DOSBox exits with a nonzero status.
A missing executable can instead raise `FileNotFoundError` while starting the process. These
behaviors are specified by the official [`subprocess.run()`
documentation](https://docs.python.org/3/library/subprocess.html#subprocess.run).

The checked status belongs to DOSBox, not directly to MASM or LINK. A normally exiting
emulator can have run a batch containing a failed tool. That is why the function continues
with a separate result check. On a subprocess exception, it never reaches that later check
or the copy-back.

## 22. Read the assembler/linker report as text

```python
report = (stage / "BUILD.LOG").read_text(errors="replace")
```

`read_text` opens, reads, and closes the file, returning a Python string. `errors="replace"`
substitutes replacement characters for byte sequences that cannot be decoded with the
selected default text encoding. It does not ignore missing-file errors or transform a failed
build into success.

If `BUILD.LOG` is missing, reading it raises an exception. The later `RuntimeError(report)`
is not reached in that case. If DOSBox exited before executing the batch and an old log
remains, this read can read that old log; deletion of the staged EXE still matters
independently.

No parser extracts a structured MASM result or counts its diagnostics. `report` is simply
the whole log text, used for a substring check and later human-readable output.

## 23. Three checks decide whether the staged executable is accepted

```python
if (
    not exe.exists()
    or not exe.read_bytes().startswith(b"MZ")
    or "error " in report.lower()
):
    raise RuntimeError(report)
```

The expression rejects the result if any condition is true. Python's `or` short-circuits:
once one condition is true, later operands are not evaluated. Thus a missing executable is
not immediately read as bytes.

`read_bytes()` loads the file's bytes. `b"MZ"` is a two-byte value, and `startswith` checks
the beginning of the file. `MZ` is the familiar DOS executable signature. This is a header
sanity check, not a complete validation of executable layout, relocations, instruction
correctness, or game behavior.

`report.lower()` makes the text comparison case-insensitive. The searched string contains a
literal space after `error`. Messages with other wording or punctuation may be missed;
harmless text containing that exact substring may trigger rejection. This heuristic does not
replace the tools' structured status reporting.

## 24. Acceptance is narrower than proving the game works

Passing the checks establishes only that this invocation reached validation, a staged file
exists with the expected first two bytes, and the report lacks that particular
case-insensitive substring. It does not establish a successful phone connection or a correct
race.

For example, a syntactically valid executable could still contain a movement bug. A tool
failure with unexpected wording could escape the text heuristic if a matching executable
also exists. The code's pre-build EXE deletion reduces one common stale-output case but does
not turn the check into a formal proof.

These are properties of the source's checks. They are not claims that any such failure
occurred during this documentation work. No builder, DOSBox session, or game was run to
write this page.

## 25. Copy-back, printed output, and the return value are different results

```python
shutil.copy2(exe, HERE / "MAZE4.EXE")
print(report.strip())
print(
    f"Built {HERE / 'MAZE4.EXE'} ({exe.stat().st_size} bytes) using supplied dos-tools binaries"
)
return HERE / "MAZE4.EXE"
```

The first line publishes the accepted staged file to `assignment-3/MAZE4.EXE`. An existing
destination is replaced by the copy. This is an ordinary file copy, not an atomic
temporary-file-and-rename scheme. A copy error can therefore leave a partially updated
destination.

`strip()` removes whitespace from both ends of the printed report. It changes neither
`report` nor `BUILD.LOG`. `exe.stat().st_size` reads the staged file's size in bytes for the
message.

Printing sends text to the caller's output stream. Returning gives a `Path` object to Python
code that called `build()`. The function does not return the log or an exit-status integer.
If a print or size-query operation raises after copying, the destination may already have
been updated even though the function does not return normally.

## 26. The main guard runs the build only for direct execution

```python
if __name__ == "__main__":
    build()
```

When this file is the executed Python program, its module name is `__main__`. The condition
is true, so it calls `build()`. There is no separate function named `main` in this file. The
top-level call does not use the returned `Path`; the printed messages provide the visible
result.

When another module imports `build_maze4`, Python executes the imports, constant
assignments, and function definitions, but this condition is false. Import alone therefore
does not stage files or run DOSBox. The launcher can import `SOURCES`, `build`, and
`environment`, then decide when to call the two functions.

Uncaught exceptions propagate to the importing caller or produce the normal Python traceback
when the script is executed directly. There is no command-line option parser or retry loop
in this file.

## 27. Failure cleanup and concurrent calls have precise limits

The file has no `try`/`finally` cleanup block and no directory-tree deletion. On failure,
staged sources, configuration, temporary files, object files, logs, and any generated output
can remain for inspection. The `with` block closes its log file, and `subprocess.run`
handles its child on timeout; those behaviors do not remove the staging directory.

A missing tool fails before copying sources and before deleting the old staged EXE. A later
assembly failure occurs after that EXE deletion. The published `assignment-3/MAZE4.EXE` is
retained until copy-back is attempted. The builder does not automatically delete that
published file on any failure.

All invocations share the same stage, filenames, logs, and destination. There is no lock or
per-invocation identifier. Concurrent builds can overwrite sources or logs, delete one
another's staged EXE, or copy results from an overlapping invocation. The source therefore
does not provide concurrency isolation.

## 28. An illustrative successful execution

Assume all source/tool files are available, DOSBox can run them, and the tools produce an
acceptable executable and report. This is a reasoning trace, not captured build output:

```text
direct execution → main guard calls build()
create/reuse stage and stage/TMP
check the three supplied tool paths
copy the four source files
write BUILD.BAT and build.conf
remove any old staged MAZE4.EXE
open/truncate dosbox.log
prepare child environment and launch DOSBox
mount stage as C and tools as T
assemble MAZE4.ASM; append linker output after successful assembly
exit DOSBox before the timeout, with a zero host exit status
read BUILD.LOG
find staged MAZE4.EXE, verify MZ prefix, find no "error " substring
copy staged EXE into assignment-3
print report and size message
return the published executable's Path
```

The game is not started anywhere in that sequence. Building prepares a file that the
separate launcher can execute later.

## 29. Illustrative failure paths

| Trigger | Where normal execution stops | What follows |
| --- | --- | --- |
| `ML.EXE` is absent | Tool loop | `RuntimeError` identifies its host path |
| An include cannot be copied | `copy2` loop | Filesystem exception propagates |
| `/usr/bin/dosbox` is absent | Process creation | Startup exception propagates |
| DOSBox exceeds the wait limit | `subprocess.run` | Timeout exception; no report validation |
| DOSBox exits nonzero | `subprocess.run` | `CalledProcessError`; no copy-back |
| Batch does not produce a log | `read_text` | Missing-file exception propagates |
| Assembly reports failure and no EXE appears | Result condition | `RuntimeError(report)` |
| Output lacks `MZ` at its beginning | Result condition | `RuntimeError(report)` |
| Report contains `Error ` | Lowercased substring check | `RuntimeError(report)` |
| Destination copy fails | Final `copy2` | Copy exception; no normal return |

For an assembly failure, `if errorlevel 1` skips LINK inside DOS. DOSBox may nevertheless
exit normally after the batch. Python then rejects the missing staged EXE or the error text.
That example shows why process success and build success are separate checks.

## 30. Source-shaped pseudocode for the whole file

```text
at module load:
    import host environment, copying, subprocess, and path facilities
    HERE ← resolved script directory
    ROOT ← HERE's parent
    SOURCES ← the four MAZE4 assembly input names

environment():
    create/reuse ROOT/.scratch/tmp
    return a copy of the host environment with three temp paths replaced

build():
    create/reuse the fixed scratch build directory and its TMP child
    require MASM.EXE, ML.EXE, and LINK.EXE under ROOT/dos-tools
    copy each named assembly input into the stage
    write the DOS batch commands and the build-only DOSBox configuration
    remove the previous staged EXE if present
    prepare DOSBox arguments: config, mounts, batch call, exit
    open the host DOSBox log for replacement
    run DOSBox with copied environment, dummy SDL drivers, timeout, exit check
    read the DOS build report with decoding replacement
    reject missing EXE, missing MZ prefix, or the exact error-text heuristic
    copy accepted EXE to HERE
    print report and destination/size message
    return destination Path

if executed as the main module:
    call build()
```

Continue with [run_maze4.md](run_maze4.md) for how the resulting executable, DOSBox serial
connection, Python bridge, and optional HTTPS tunnel are started and supervised. Use
[MAZE4.md](MAZE4.md) for the game itself.
