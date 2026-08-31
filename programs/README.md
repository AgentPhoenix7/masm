# MASM Level 1 solutions

These programs answer all five questions in `question.jpeg`. They use 16-bit
8086 instructions, DOS interrupt `21H`, Microsoft MASM 5.10, and the matching
Microsoft linker inside DOSBox.

## Build in DOSBox

```dos
mount c /home/agntdrgn/masm/programs
mount t /home/agntdrgn/masm/dos-tools
c:
path t:\
buildall
```

`BUILDALL.BAT` assembles and links Q1, Q2, Q3, Q4, and Q5 directly, one
after another - each is a single self-contained source file, so there is
no separate library-build step and no extra demo program to link.

To execute everything, use:

```dos
runall
```

`RUNALL.BAT` runs `Q1.EXE` through `Q5.EXE` once each, interactively; it
pauses at each program's own prompts and does not redirect input from any
fixture file.

The calculator can also be used interactively:

```dos
q4
```

## How each answer demonstrates its required change

### Q1.ASM - transformed block transfer

- Reserves the source at offset `DS:3000H` and destination at `DS:4000H`.
- Reads ten decimal byte values (`0` through `255`) and stores them at
  `DS:3000H`.
- Applies `(value * 5) + 10` before storing each destination byte.
- Prints the ten transformed values in decimal.
- If a transformed value exceeds `255`, the destination stores its low byte.

Expected destination:

```text
10 15 55 60 135 255 4 254 242 5
```

Run `q1`, enter one value at each prompt, and press Enter. The verified run
uses `0`, `1`, `9`, `10`, `25`, `49`, `50`, `100`, `200`, and `255`, entered
as keyboard input with `xdotool`. `EVIDENCE/Q1RUN.TXT` contains that run.

### Q2.ASM - 20-number zig-zag array

- Prompts interactively for twenty decimal bytes (`0` through `255`), one
  per line, each read with DOS buffered keyboard input and echoed back
  after the `Enter decimal byte (0-255):` prompt.
- Stores the twenty values directly at offset `DS:4000H`.
- Rearranges the array in place with the relation
  `a0 < a1 > a2 < a3 > ...`, swapping each adjacent pair that does not
  already satisfy the required inequality.
- Prints the original array and the rearranged (zig-zag) array.

Run `q2`, then enter the twenty values one at a time, each followed by
Enter. The verified run uses
`18 5 25 2 17 8 31 4 22 10 27 1 13 7 29 3 20 9 24 6`, which produces:

```text
5 25 2 18 8 31 4 22 10 27 1 17 7 29 3 20 9 24 6 13
```

`EVIDENCE/Q2RUN.TXT` contains that run's full transcript, and
`screenshots/q2.png` shows the same session in the DOSBox window.

### Q3.ASM - hexadecimal to ASCII

- Prompts interactively for one hex byte (`00` through `FF`) typed as two
  hex digits.
- Converts the two typed digits into the corresponding byte value and
  prints it back as `Hex value: <XX>H`.
- If the byte falls in the printable ASCII range, also prints
  `ASCII value: <character>`; otherwise reports it is not printable.

Run `q3` and type two hex digits at the prompt. The verified run enters
`68`, producing:

```text
Hex value: 68H
ASCII value: h
```

`EVIDENCE/Q3RUN.TXT` and `screenshots/q3.png` capture that run.

### Q4.ASM - basic calculator

- Prompts interactively for a first operand, an operator, and a second
  operand, each read with DOS buffered keyboard input.
- Accepts unsigned decimal operands from 0 through 255.
- Supports addition, signed-result subtraction, multiplication, and division.
- Division reports both quotient and remainder and rejects division by zero.
- Rejects invalid numbers and unsupported operators.

Run `q4` and answer its three prompts (`First operand:`,
`Operator (+, -, *, /):`, `Second operand:`) for one calculation per
invocation. The verified demonstration runs (one program invocation each)
are:

| First | Operator | Second | Result |
| ----- | -------- | ------ | ------ |
| `12`  | `+`      | `5`    | `Result: 17` |
| `5`   | `-`      | `12`   | `Result: -7` |
| `25`  | `*`      | `10`   | `Result: 250` |
| `29`  | `/`      | `4`    | `Quotient: 7  Remainder: 1` |
| `29`  | `/`      | `0`    | `ERROR: division by zero.` |

`EVIDENCE/Q4ADD.OUT`, `Q4SUB.OUT`, `Q4MUL.OUT`, `Q4DIV.OUT`, and
`Q4ZERO.OUT` each capture one of these five runs, and
`screenshots/q4-add.png`, `q4-subtract.png`, `q4-multiply.png`,
`q4-divide.png`, and `q4-zero.png` show the same five cases in the DOSBox
window.

### Q5.ASM - string operations

Q5 contains three library-style, zero-terminated-string procedures in one
standalone source file - `STRLEN`, `STRCMP`, and `STRREV` - rather than a
separate `STRLIB.LIB` static library plus a `Q5DEMO.EXE` client linked
against it. That consolidation was an explicitly approved design change:
one interactive, self-contained program is simpler to build and run than
a library-plus-demo pair, with no loss of the procedures themselves.

- `STRLEN`: `DS:SI` points to the string; returns its length in `AX`.
- `STRCMP`: `DS:SI` and `DS:DI` point to the strings; returns `FFFFH`, `0`,
  or `1` for less than, equal, or greater than.
- `STRREV`: `DS:SI` points to a writable string; reverses it in place and
  returns its length in `AX`.

The program prompts interactively for two strings (up to 30 characters
each), then prints both lengths, the comparison result, and the first
string reversed.

Run `q5` and type each string at its prompt (`String 1:`, `String 2:`).
The verified run enters `NETWORK` then `NETWORL`, producing:

```text
Length of string 1: 7
Length of string 2: 7
Comparison: string 1 is less than string 2
Reversed string 1: KROWTEN
```

`EVIDENCE/Q5RUN.TXT` and `screenshots/q5.png` capture that run.

## Evidence

Text captures of every verified run are stored under `EVIDENCE/`. DOSBox
window screenshots are stored in `screenshots/` at the repository root
(a sibling of this `programs/` directory):

- `q1.png`, `q2.png`, `q3.png`
- `q4-add.png`, `q4-subtract.png`, `q4-multiply.png`, `q4-divide.png`,
  `q4-zero.png`
- `q5.png`

All five executables were assembled and linked successfully in DOSBox 0.74-3.
The assembler reported zero warning errors and zero severe errors for every
source file.
