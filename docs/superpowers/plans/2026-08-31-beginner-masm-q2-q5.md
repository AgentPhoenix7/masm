# Beginner MASM Q2-Q5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Q2-Q5 with self-contained beginner programs that read user input, perform only the required assignment operation, and print the result.

**Architecture:** Each question is a standalone DOS `.EXE` containing a short labelled assignment algorithm followed by its own keyboard and display helpers. Q5 becomes a single `Q5.ASM`; shared includes, redirected fixtures, and the separate static-library build are removed only after every replacement builds and passes interactive DOSBox verification.

**Tech Stack:** 8086 real-mode assembly, Microsoft MASM 5.10, LINK 3.65, DOS interrupt `21H`, DOSBox 0.74-3, and `xdotool` keyboard automation.

**Spec:** `docs/superpowers/specs/2026-08-31-beginner-masm-q2-q5-design.md`

## Global Constraints

- Every executable takes its values from the keyboard and prints its result.
- Keep Q2, Q3, Q4, and Q5 self-contained; none may include `COMMON.INC`.
- Use only 8086-compatible instructions and MASM 5.10 syntax.
- Use DOS buffered keyboard input and verify interactively with `xdotool`, not redirected input fixtures.
- Build and link only inside DOSBox with the supplied Microsoft tools.
- Keep input validation limited to the ranges and characters required for truthful output.

---

### Task 1: Interactive Q2 Zig-Zag Array

**Files:**
- Modify: `programs/Q2.ASM`
- Regenerate: `programs/Q2.OBJ`
- Regenerate: `programs/Q2.EXE`

**Interfaces:**
- Consumes: 20 distinct decimal byte values, one keyboard line per value.
- Produces: the original and in-place zig-zag arrays at `DS:4000H`, printed in decimal.
- Local procedures: `READ_BYTE` returns `AL` and carry status; `PRINT_BYTE`, `PRINT_ARRAY`, `PRINT_STRING`, and `PRINT_NEWLINE` preserve the outer loop counter.

- [ ] **Step 1: Run the structural failing test**

Run:

```bash
rg -n 'INPUT_ARRAY DB|INCLUDE COMMON.INC' programs/Q2.ASM
```

Expected before the rewrite: matches proving Q2 still uses a hard-coded array and the shared include.

- [ ] **Step 2: Replace the hard-coded data flow with keyboard input**

Define the destination directly at the required offset:

```asm
    ORG 4000H
ZIGZAG_ARRAY DB 20 DUP (0)
```

Read the 20 values into that array:

```asm
    MOV DI, 4000H
    MOV CX, 20
INPUT_LOOP:
    LEA DX, PROMPT_TEXT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC INPUT_OK
    JMP BAD_INPUT
INPUT_OK:
    MOV [DI], AL
    INC DI
    CALL PRINT_NEWLINE
    LOOP INPUT_LOOP
```

The self-contained `READ_BYTE` must use DOS function `0AH`, accept one to three decimal digits, reject values above `255`, and preserve `BX`, `CX`, `DX`, and `SI`.

- [ ] **Step 3: Keep only the required zig-zag algorithm**

Use this in-place adjacent-pair loop:

```asm
    MOV SI, 4000H
    MOV CX, 19
    XOR BL, BL
ZIGZAG_LOOP:
    MOV AL, [SI]
    MOV AH, [SI+1]
    TEST BL, 1
    JNZ WANT_GREATER
    CMP AL, AH
    JB PAIR_OK
    JMP SHORT SWAP_PAIR
WANT_GREATER:
    CMP AL, AH
    JA PAIR_OK
SWAP_PAIR:
    MOV [SI], AH
    MOV [SI+1], AL
PAIR_OK:
    INC SI
    INC BL
    LOOP ZIGZAG_LOOP
```

Print `Original array:` before this loop and `Zig-zag array:` after it. `PRINT_ARRAY` must call `PRINT_BYTE` for exactly 20 elements.

- [ ] **Step 4: Assemble and link Q2**

Run in DOSBox:

```dos
MASM Q2.ASM;
LINK Q2.OBJ;
```

Expected: zero warning errors, zero severe errors, and `Q2.EXE` created.

- [ ] **Step 5: Verify Q2 interactively**

Use `xdotool` to enter:

```text
18 5 25 2 17 8 31 4 22 10 27 1 13 7 29 3 20 9 24 6
```

Expected printed zig-zag array:

```text
5 25 2 18 8 31 4 22 10 27 1 17 7 29 3 20 9 24 6 13
```

Check every adjacent relation is strictly `< > < > ...`.

- [ ] **Step 6: Commit Q2**

```bash
git add programs/Q2.ASM
git commit -m "refactor: simplify interactive Q2 zig-zag program"
```

---

### Task 2: Q3 Hex Byte to ASCII Character

**Files:**
- Modify: `programs/Q3.ASM`
- Regenerate: `programs/Q3.OBJ`
- Regenerate: `programs/Q3.EXE`

**Interfaces:**
- Consumes: exactly two hexadecimal digits from `00` through `FF`.
- Produces: the ASCII character represented by the byte, or `not printable` outside `20H` through `7EH`.
- Local procedure: `HEX_NIBBLE` accepts one ASCII hex digit in `AL`, returns its value in `AL`, and sets carry for invalid input.

- [ ] **Step 1: Run the behavioral failing test**

Run the current `Q3.EXE` in DOSBox.

Expected before the rewrite: it immediately uses hard-coded `3FA7H` and never prompts for `68`.

- [ ] **Step 2: Replace the word conversion with one-byte user input**

Use a DOS input buffer capable of two typed characters plus Enter:

```asm
INPUT_BUFFER DB 3,0,4 DUP (0)
```

Require `INPUT_BUFFER[1] == 2`. Convert the two digits as follows:

```asm
    MOV AL, INPUT_BUFFER[2]
    CALL HEX_NIBBLE
    JC BAD_INPUT
    MOV BL, AL
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1
    SHL BL, 1

    MOV AL, INPUT_BUFFER[3]
    CALL HEX_NIBBLE
    JC BAD_INPUT
    OR BL, AL
```

`HEX_NIBBLE` must accept `0-9`, `A-F`, and `a-f`, returning values `0-15`.

- [ ] **Step 3: Print the ASCII result**

First print the normalized input value using the two characters in `INPUT_BUFFER`, followed by `H`:

```asm
    LEA DX, HEX_LABEL
    CALL PRINT_STRING
    MOV DL, INPUT_BUFFER[2]
    MOV AH, 02H
    INT 21H
    MOV DL, INPUT_BUFFER[3]
    MOV AH, 02H
    INT 21H
    MOV DL, 'H'
    MOV AH, 02H
    INT 21H
    CALL PRINT_NEWLINE
```

For `20H <= BL <= 7EH`, print `BL` with DOS function `02H`:

```asm
    LEA DX, ASCII_LABEL
    CALL PRINT_STRING
    MOV DL, BL
    MOV AH, 02H
    INT 21H
```

For other byte values, print `ASCII value: not printable`. Do not emit a control character.

- [ ] **Step 4: Assemble, link, and verify Q3**

Run in DOSBox:

```dos
MASM Q3.ASM;
LINK Q3.OBJ;
Q3
```

Enter `68` with `xdotool` and press Enter.

Expected:

```text
Hex value: 68H
ASCII value: h
```

Also enter `0A`; expected: `ASCII value: not printable`.

- [ ] **Step 5: Commit Q3**

```bash
git add programs/Q3.ASM
git commit -m "refactor: convert interactive hex byte to ASCII in Q3"
```

---

### Task 3: Self-Contained Interactive Q4 Calculator

**Files:**
- Modify: `programs/Q4.ASM`
- Regenerate: `programs/Q4.OBJ`
- Regenerate: `programs/Q4.EXE`

**Interfaces:**
- Consumes: unsigned byte, one operator, unsigned byte.
- Produces: signed subtraction, 16-bit addition/product, or quotient and remainder.
- Local procedures: `READ_BYTE`, `READ_OPERATOR`, `PRINT_UINT`, `PRINT_STRING`, `PRINT_CHAR`, and `PRINT_NEWLINE`.

- [ ] **Step 1: Run the structural failing test**

Run:

```bash
rg -n 'INCLUDE COMMON.INC|MOV AH, 01H|DISCARD_LINE' programs/Q4.ASM
```

Expected before the rewrite: matches proving Q4 still depends on the shared include and character-by-character redirected-input handling.

- [ ] **Step 2: Replace input with two small buffered readers**

`READ_BYTE` must use DOS function `0AH`, accept one to three decimal digits, reject non-digits and values above `255`, return the value in `AX` with carry clear, return carry set for invalid input, and preserve `BX`, `CX`, `DX`, and `SI`. `READ_OPERATOR` must use DOS function `0AH`, require exactly one typed character, and accept only `+`, `-`, `*`, or `/`.

The main input flow is:

```asm
    LEA DX, FIRST_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC FIRST_OK
    JMP BAD_INPUT
FIRST_OK:
    XOR AH, AH
    MOV OPERAND1, AX

    LEA DX, OPERATOR_PROMPT
    CALL PRINT_STRING
    CALL READ_OPERATOR
    JNC OPERATOR_OK
    JMP BAD_OPERATOR
OPERATOR_OK:
    MOV OPERATOR, AL

    LEA DX, SECOND_PROMPT
    CALL PRINT_STRING
    CALL READ_BYTE
    JNC SECOND_OK
    JMP BAD_INPUT
SECOND_OK:
    XOR AH, AH
    MOV OPERAND2, AX
```

- [ ] **Step 3: Retain the four minimal arithmetic branches**

Use 16-bit `ADD` and `MUL`, print a leading minus sign when `OPERAND1 < OPERAND2`, and use `XOR DX,DX` before unsigned `DIV`. Division by zero must branch to a short error message before `DIV`.

- [ ] **Step 4: Assemble and link Q4**

Run in DOSBox:

```dos
MASM Q4.ASM;
LINK Q4.OBJ;
```

Expected: zero warning errors and zero severe errors.

- [ ] **Step 5: Verify all Q4 branches with xdotool**

Run Q4 separately for each case:

```text
12 + 5  -> Result: 17
5  - 12 -> Result: -7
25 * 10 -> Result: 250
29 / 4  -> Quotient: 7  Remainder: 1
29 / 0  -> ERROR: division by zero.
```

- [ ] **Step 6: Commit Q4**

```bash
git add programs/Q4.ASM
git commit -m "refactor: simplify self-contained Q4 calculator"
```

---

### Task 4: Standalone Q5 String Operations

**Files:**
- Create: `programs/Q5.ASM`
- Regenerate: `programs/Q5.OBJ`
- Regenerate: `programs/Q5.EXE`

**Interfaces:**
- Consumes: two user-entered strings of at most 30 characters each.
- Produces: both lengths, lexical comparison, and the reversed first string.
- Procedures: `STRLEN`, `STRCMP`, `STRREV`, `READ_STRING`, `PRINT_Z`, `PRINT_UINT`, `PRINT_STRING`, and `PRINT_NEWLINE`.

- [ ] **Step 1: Run the behavioral failing test**

Run the current `Q5DEMO.EXE`.

Expected before the replacement: it uses hard-coded `NETWORK` and `NETWORL` and never prompts for strings.

- [ ] **Step 2: Create Q5 data buffers and keyboard flow**

Use DOS buffered strings:

```asm
STRING1_BUFFER DB 31,0,31 DUP (0)
STRING2_BUFFER DB 31,0,31 DUP (0)
```

`READ_STRING` receives the buffer address in `DX`, calls DOS function `0AH`, and replaces the terminating carriage return with a zero byte:

```asm
    MOV SI, DX
    XOR BX, BX
    MOV BL, [SI+1]
    ADD SI, BX
    MOV BYTE PTR [SI+2], 0
```

The zero-terminated string begins at buffer offset `+2`.

- [ ] **Step 3: Put all three required operations in Q5.ASM**

Keep these exact contracts:

```text
STRLEN: DS:SI -> string; AX <- length; preserve SI
STRCMP: DS:SI, DS:DI -> strings; AX <- FFFFH, 0, or 1; preserve SI and DI
STRREV: DS:SI -> writable string; reverse in place; AX <- length; preserve SI
```

Implement `STRLEN` as a zero-byte scan, `STRCMP` as a byte-by-byte unsigned lexical comparison, and `STRREV` as inward swaps for `length / 2` iterations.

- [ ] **Step 4: Print every required result**

For inputs `NETWORK` and `NETWORL`, expected output includes:

```text
Length of string 1: 7
Length of string 2: 7
Comparison: string 1 is less than string 2
Reversed string 1: KROWTEN
```

- [ ] **Step 5: Assemble and link standalone Q5**

Run in DOSBox:

```dos
MASM Q5.ASM;
LINK Q5.OBJ;
Q5
```

Enter `NETWORK` and `NETWORL` with `xdotool`; verify the expected output above.

- [ ] **Step 6: Commit Q5**

```bash
git add programs/Q5.ASM
git commit -m "feat: add standalone interactive Q5 string operations"
```

---

### Task 5: Build Integration and Obsolete-File Cleanup

**Files:**
- Modify: `programs/BUILDALL.BAT`
- Modify: `programs/RUNALL.BAT`
- Delete: `programs/COMMON.INC`
- Delete: `programs/STRLIB.ASM`
- Delete: `programs/Q5DEMO.ASM`
- Delete: `programs/Q4ADD.IN`
- Delete: `programs/Q4SUB.IN`
- Delete: `programs/Q4MUL.IN`
- Delete: `programs/Q4DIV.IN`
- Remove generated artifacts: `programs/STRLIB.OBJ`, `programs/STRLIB.LIB`, `programs/Q5DEMO.OBJ`, `programs/Q5DEMO.EXE`, `programs/Q5DEMO.MAP`

**Interfaces:**
- Consumes: independently verified `Q1.ASM` through `Q5.ASM`.
- Produces: one direct assemble/link path per question and no static-library dependency.

- [ ] **Step 1: Prove cleanup is not yet safe**

Run:

```bash
rg -n 'COMMON.INC|STRLIB|Q5DEMO' programs/*.ASM programs/*.BAT
```

Expected before integration: references remain in the old sources and build scripts.

- [ ] **Step 2: Update BUILDALL.BAT**

Replace the STRLIB/Q5DEMO block with:

```bat
ECHO Building Q5...
MASM Q5.ASM;
IF ERRORLEVEL 1 GOTO FAILED
LINK Q5.OBJ;
IF ERRORLEVEL 1 GOTO FAILED
```

The success line must say `ALL FIVE QUESTIONS BUILT SUCCESSFULLY.`

- [ ] **Step 3: Update RUNALL.BAT**

Run `Q1.EXE` through `Q5.EXE` once each. Remove every redirected Q4 fixture invocation. The script is interactive and pauses naturally at each program's prompts.

- [ ] **Step 4: Run a full build before deleting old files**

Run in DOSBox:

```dos
BUILDALL
```

Expected: all five assemble and link successfully with zero warning and zero severe errors.

- [ ] **Step 5: Delete only the now-obsolete files**

Remove the exact source, fixture, and generated-artifact paths listed in this task's Files section. Confirm no remaining source or batch file refers to them:

```bash
if rg -n 'COMMON.INC|STRLIB|Q5DEMO|Q4ADD|Q4SUB|Q4MUL|Q4DIV' programs/*.ASM programs/*.BAT; then
  exit 1
fi
```

- [ ] **Step 6: Commit build integration and cleanup**

```bash
git add -A programs
git commit -m "build: use standalone interactive MASM programs"
```

---

### Task 6: Documentation, Evidence, and Final Verification

**Files:**
- Modify: `programs/README.md`
- Regenerate: `programs/EVIDENCE/Q2RUN.TXT`
- Regenerate: `programs/EVIDENCE/Q3RUN.TXT`
- Regenerate: Q4 evidence files for the five verified branches
- Regenerate: `programs/EVIDENCE/Q5RUN.TXT`
- Delete: `programs/EVIDENCE/STRLIST.TXT`
- Regenerate: `screenshots/q2.png`
- Regenerate: `screenshots/q3.png`
- Regenerate: Q4 screenshots
- Regenerate: `screenshots/q5.png`

**Interfaces:**
- Consumes: the final five executables and the exact demonstration inputs in Tasks 1-4.
- Produces: current user-facing instructions and auditable xdotool-driven output evidence.

- [ ] **Step 1: Update README.md**

Document the interactive input format, expected output, and core algorithm for each question. Remove all instructions for Q4 `.IN` files and the STRLIB `.LIB` workflow. State that Q5 contains library-style procedures in one standalone source because that trade-off was explicitly approved.

- [ ] **Step 2: Capture text evidence with keyboard input**

For each program, start it with DOS output redirected only to its evidence file, then use `xdotool` for keyboard input. This redirects output, not input, so DOS keyboard line handling remains unchanged.

- [ ] **Step 3: Capture and inspect screenshots**

Run each executable normally, enter values with `xdotool`, and capture the 640x400 DOSBox window. Inspect every screenshot before replacing the corresponding file in `screenshots/`.

- [ ] **Step 4: Run the final full build**

Run in DOSBox:

```dos
BUILDALL
```

Read the complete output. Required result: all five programs report zero warning errors and zero severe errors, and the batch file prints `ALL FIVE QUESTIONS BUILT SUCCESSFULLY.`

- [ ] **Step 5: Check final source invariants**

Run:

```bash
test -f programs/Q1.ASM
test -f programs/Q2.ASM
test -f programs/Q3.ASM
test -f programs/Q4.ASM
test -f programs/Q5.ASM
test ! -e programs/COMMON.INC
test ! -e programs/STRLIB.ASM
test ! -e programs/Q5DEMO.ASM
rg -n 'ORG 4000H' programs/Q2.ASM
rg -n 'Hex value:|ASCII value:' programs/Q3.ASM
rg -n 'STRLEN|STRCMP|STRREV' programs/Q5.ASM
```

- [ ] **Step 6: Commit documentation and evidence**

```bash
git add programs/README.md programs/EVIDENCE screenshots
git commit -m "docs: refresh interactive MASM evidence"
```
