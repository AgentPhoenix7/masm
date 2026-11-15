# Assignment 3 — maze programs explained from 8085 knowledge

These guides use the numbered instruction walkthroughs, worked examples,
pseudocode, and 8085 comparisons established in
[Assignment 1](../../assignment-1/explanations/).

| Program | Guide | What this version introduces |
| --- | --- | --- |
| [MAZE.ASM](../MAZE.ASM) | [MAZE](MAZE.md) | One player, arrow-key events, row/column addressing, BIOS drawing |
| [MAZE2.ASM](../MAZE2.ASM) | [MAZE2](MAZE2.md) | Two players, held keys and quick taps, keyboard interrupts, timed frames, step counts |
| [MAZE3.ASM](../MAZE3.ASM) | [MAZE3](MAZE3.md) | Three-player race, proposed moves, collision episodes, finish time and tied winners |
| [MAZE4.ASM](../MAZE4.ASM) | [MAZE4](MAZE4.md) | Generated mazes, BFS fairness, up to eight players, serial phone input, sessions and lifecycle |

Read them in this order. Each guide explains the actual version rather than
assuming that an older header comment names it correctly.

`MAZE.ASM` currently contains a repeated program block inside its first drawing
procedure. Its guide identifies the malformed layout and explains the intended
single-copy logic; it does not claim that the checked-in source builds.

MAZE2 updates player 1 and then player 2 within a frame. MAZE3 and MAZE4 instead
build all proposals before resolving collisions and committing movement.
That distinction affects occupied cells, following moves, and conflicts.

MAZE4's guide covers all three assembly includes:

- [M4CORE.INC](../M4CORE.INC): DFS generation, BFS, start selection, movement,
  collision resolution, proximity warnings, and scores.
- [M4SER.INC](../M4SER.INC): UART framing, request validation, ownership,
  input expiry, disconnection, snapshots, and clocks.
- [M4UI.INC](../M4UI.INC): main loop, host controls, keyboard interrupt,
  video memory, and scoreboard.

It also follows the supporting Python/browser transport so you can trace a
phone button through to an assembly movement decision. MASM owns the game
rules; the bridge provides authenticated transport.

For installation and running MAZE4, use the existing [runtime README](../README.md).
For earlier runtime evidence and its limits, see [VERIFICATION.md](../VERIFICATION.md).
The study guides themselves do not claim new game or physical-phone tests.
