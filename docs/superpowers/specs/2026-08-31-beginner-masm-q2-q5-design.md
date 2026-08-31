# Beginner MASM Q2-Q5 Simplification Design

## Goal

Rewrite Questions 2 through 5 as beginner-oriented, self-contained MASM 5.10 programs. Every executable must take its data from the user through the keyboard and print its result. The programs must continue to satisfy the wording in `question.jpeg` and use only 8086-compatible instructions and DOS interrupt `21H` services.

## Shared Style

- Keep each question in one `.ASM` file so it can be studied without opening `COMMON.INC`.
- Put the short assignment algorithm in a clearly labelled main section.
- Put unavoidable keyboard parsing and number-printing procedures after the main program.
- Use DOS buffered keyboard input. Interactive verification will type values with `xdotool`; redirected input fixtures will not be used.
- Validate the input needed to prevent incorrect or invisible output, but do not add unrelated features.
- Build and verify with MASM 5.10 and LINK 3.65 inside DOSBox.

## Q2: Zig-Zag Array

`Q2.ASM` will ask the user for 20 decimal byte values from 0 through 255. It will store them at `DS:4000H`, print the original array, rearrange the array in place so that `a0 < a1 > a2 < a3 > ...`, and print the rearranged array.

The demonstration input will use distinct values because equal adjacent values cannot satisfy a strict less-than or greater-than relation. The program will validate the byte range but will not add a duplicate-detection subsystem.

## Q3: Hexadecimal Value to ASCII

`Q3.ASM` will ask the user for one two-digit hexadecimal byte value. It will convert those two hexadecimal digits into one numeric byte and print the ASCII character represented by that byte.

Example:

```text
Hex value: 68H
ASCII value: h
```

The input must contain exactly two hexadecimal digits (`0-9`, `A-F`, or `a-f`). Printable ASCII codes will be displayed as characters; a non-printable code will produce a clear `not printable` message instead of emitting a control character.

## Q4: Basic Calculator

`Q4.ASM` will ask for the first unsigned byte, one operator (`+`, `-`, `*`, or `/`), and the second unsigned byte. It will print the result. Subtraction may print a negative result, multiplication will retain the full 16-bit product, and division will print both quotient and remainder. Division by zero and invalid input will print short error messages.

The program will be self-contained and will be tested through interactive keyboard input rather than `.IN` redirection files.

## Q5: String Operations in One File

`Q5.ASM` will be one standalone program. It will ask the user for two strings and contain the three required procedures in the same file:

- `STRLEN` returns a string's length.
- `STRCMP` compares the two strings.
- `STRREV` reverses the first string in place.

The program will print both lengths, the comparison result, and the reversed first string. This is a library-style collection of procedures in one source file; it intentionally replaces the previous separate `.LIB` build because the user approved that trade-off.

## Files and Build Changes

- Rewrite `Q2.ASM`, `Q3.ASM`, and `Q4.ASM`.
- Add standalone `Q5.ASM`.
- Retire `COMMON.INC`, `STRLIB.ASM`, and `Q5DEMO.ASM` after their replacements build successfully.
- Remove obsolete Q4 redirected-input fixtures and old STRLIB/Q5DEMO generated artifacts.
- Update `BUILDALL.BAT` to assemble and link `Q1.ASM` through `Q5.ASM` directly.
- Update `RUNALL.BAT`, `README.md`, text evidence, and screenshots for the new interactive programs.

## Verification

1. Build all five programs inside DOSBox with MASM 5.10 and LINK 3.65, requiring zero warning and zero severe errors.
2. Use `xdotool` to enter all demonstration values in real DOSBox windows.
3. Verify Q2's printed array satisfies every alternating relation.
4. Verify Q3 prints `h` for input `68H`.
5. Verify Q4 addition, negative subtraction, multiplication, division with remainder, and division-by-zero behavior.
6. Verify Q5 prints correct lengths, comparison, and reversal for two user-entered strings.
7. Regenerate the matching evidence files and screenshots only from these verified runs.
