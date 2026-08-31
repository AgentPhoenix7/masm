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

`BUILDALL.BAT` assembles and links Q1 through Q4, creates the real static
library `STRLIB.LIB`, and links `Q5DEMO.EXE` against that library.

To execute everything, use:

```dos
runall
```

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

- Copies the twenty-number input to offset `DS:4000H`.
- Rearranges the copy in place with the relation
  `a0 < a1 > a2 < a3 > ...`.
- Checks all nineteen adjacent relations and prints `PASS` only if they hold.

Run `q2`. It prints the input, the contents at `DS:4000H` before and after
rearrangement, and the verification result.

### Q3.ASM - hexadecimal to ASCII

- Stores the numeric word `3FA7H`, not an already formatted text string.
- Converts its four nibbles to the ASCII characters `3FA7`.
- Shows the output buffer changing from `00 00 00 00` to
  `33 46 41 37`, the ASCII byte values for `3`, `F`, `A`, and `7`.

Run `q3` to show both the readable result and the underlying byte change.

### Q4.ASM - basic calculator

- Accepts unsigned decimal operands from 0 through 255.
- Supports addition, signed-result subtraction, multiplication, and division.
- Division reports both quotient and remainder and rejects division by zero.
- Rejects invalid numbers and unsupported operators.

Run `q4` for interactive use. The supplied input fixtures demonstrate all
operations noninteractively:

```dos
q4 < q4add.in
q4 < q4sub.in
q4 < q4mul.in
q4 < q4div.in
```

They produce `17`, `-7`, `250`, and quotient `7` with remainder `1`.
`EVIDENCE/Q4ZERO.OUT` and `EVIDENCE/Q4BAD.OUT` show the verified error paths
for division by zero and an unsupported operator.

### STRLIB.ASM and Q5DEMO.ASM - string operation library

`STRLIB.ASM` exports three zero-terminated-string procedures:

- `STRLEN`: `DS:SI` points to the string; returns its length in `AX`.
- `STRCMP`: `DS:SI` and `DS:DI` point to the strings; returns `FFFFH`, `0`, or
  `1` for less than, equal, or greater than.
- `STRREV`: `DS:SI` points to a writable string; reverses it in place and
  returns its length in `AX`.

`STRLIB.LIB` is an actual Microsoft OMF library, not just a source file named
"library." `Q5DEMO.EXE` is a separate client linked against it. Run `q5demo`
to show both lengths, comparison, and the in-place change from `NETWORK` to
`KROWTEN`. `EVIDENCE/STRLIST.TXT` lists all three public library symbols.

## Evidence

Text captures of every verified run are stored under `EVIDENCE/`. DOSBox
window screenshots are stored in `/home/agntdrgn/masm/screenshots/`:

- `q1.png`, `q2.png`, `q3.png`
- `q4-add.png`, `q4-subtract.png`, `q4-multiply.png`, `q4-divide.png`
- `q5.png`

All five executables were assembled and linked successfully in DOSBox 0.74-3.
The assembler reported zero warning errors and zero severe errors for every
source file.
