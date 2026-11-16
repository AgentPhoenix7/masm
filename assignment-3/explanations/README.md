# Assignment 3 — maze programs explained from 8085 knowledge

These are source-based guides with numbered instruction walkthroughs, worked
examples, pseudocode, and comparisons with basic 8085 programming concepts.
Choose the program you are studying; its guide explains that program's state
and execution rather than requiring the previous maze versions.

| Program | Guide | Main topics |
| --- | --- | --- |
| [MAZE.ASM](../MAZE.ASM) | [MAZE](MAZE.md) | One player, arrow-key events, row/column addressing, BIOS drawing |
| [MAZE2.ASM](../MAZE2.ASM) | [MAZE2](MAZE2.md) | Two players, held keys and quick taps, keyboard interrupts, timed frames, step counts |
| [MAZE3.ASM](../MAZE3.ASM) | [MAZE3](MAZE3.md) | Three-player race, proposed moves, collision episodes, finish time and tied winners |
| [MAZE4.ASM](../MAZE4.ASM) | [MAZE4](MAZE4.md) | Generated mazes, BFS fairness, up to eight players, serial phone input, sessions and lifecycle |

The MAZE4 explanation and its companion guides form a self-contained set.
You can begin with [MAZE4](MAZE4.md) directly; the other maze programs are
separate studies. Each guide describes the file named in its source link.

`MAZE.ASM` currently contains a repeated program block inside its first drawing
procedure. Its guide identifies the malformed layout and explains the intended
single-copy logic; it does not claim that the checked-in source builds.

MAZE4 also has separate guides for its supporting include files:

| Source | Detailed guide | Topics |
| --- | --- | --- |
| [M4CORE.INC](../M4CORE.INC) | [M4CORE](M4CORE.md) | DFS generation, BFS, equal-distance starts, movement proposals, collision passes, warnings, scores |
| [M4SER.INC](../M4SER.INC) | [M4SER](M4SER.md) | UART setup, framing and parsing, request validation, sessions, leases, snapshots, lifecycle, clock arithmetic |
| [M4UI.INC](../M4UI.INC) | [M4UI](M4UI.md) | Main loop, host controls, keyboard interrupts, video memory, drawing helpers, roster and scoreboard |

Read the [MAZE4 overview](MAZE4.md) for the complete system, then the module
guides for detailed procedure and instruction walkthroughs. Each module guide
includes worked traces, register contracts, pseudocode, and 8085 comparisons.
The `.INC` files are inserted into `MAZE4.ASM` during assembly; they share its
state and are not separate executables.

The Python support files have their own standalone walkthroughs:

| Source | Detailed guide | Topics |
| --- | --- | --- |
| [build_maze4.py](../build_maze4.py) | [Build script](build_maze4.md) | Paths and environment, staging, DOS batch commands, DOSBox, build checks and outputs |
| [run_maze4.py](../run_maze4.py) | [Launcher](run_maze4.md) | Arguments, startup order, threads, tunnel readiness, traces, process cleanup |
| [phone/protocol.py](../phone/protocol.py) | [Serial protocol](protocol.md) | Binary records, framing, TCP reads, parser state, locks, ACKs, retries and freshness |
| [phone/bridge.py](../phone/bridge.py) | [HTTP bridge](bridge.md) | Room synchronization, credentials, joins, request validation, commands, private status and workers |

The support guides introduce the current MAZE4 interfaces and the Python
concepts they use. Their cross-links are companion references, not prerequisites
to older versions. The complete path is browser → HTTP bridge → serial protocol
→ DOSBox COM1 → MASM rules → state snapshot → controller status.
MASM owns the game rules; Python supplies build, process, authentication, and
transport services.

For installation and running MAZE4, use the existing [runtime README](../README.md).
For earlier runtime evidence and its limits, see [VERIFICATION.md](../VERIFICATION.md).
The study guides themselves do not claim new game or physical-phone tests.
