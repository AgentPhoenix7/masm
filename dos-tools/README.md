# DOS MASM toolchain

This directory contains the DOS tools selected for the supplied 8086 lab:

- `MASM.EXE`: Microsoft Macro Assembler 5.10.
- `LINK.EXE`: Microsoft Segmented-Executable Linker 3.65.
- `LIB.EXE`: Microsoft Library Manager 3.10.
- `DEBUG.COM`: FreeDOS DEBUG 2.50.

`DEBUG.COM` is the debugger's correct DOS executable name. DOS resolves the
command `DEBUG program.exe` to `DEBUG.COM`; it must not be renamed to
`DEBUG.EXE`, because COM and EXE files have different executable formats.

## Sources

- MASM and LINK:
  <https://github.com/microsoft/MS-DOS/tree/main/v4.0/src/TOOLS>
- DEBUG package:
  <https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/repositories/1.3/html/en/base/debug/20240624.0/index.html>

The Microsoft repository and FreeDOS DEBUG are MIT-licensed. Supporting
license and package metadata are retained in `docs/`.

## Verified versions

Verified in DOSBox 0.74-3 on 2026-08-10:

- Microsoft Macro Assembler 5.10
- Microsoft Overlay Linker 3.65
- Microsoft Library Manager 3.10
- FreeDOS DEBUG 2.50

A temporary 8086 program assembled with zero warnings and zero errors, linked
to an MZ executable, printed `MASM DOS toolchain OK`, and was successfully
loaded by DEBUG for register inspection.

## SHA-256

```text
1c6286c69b616160b8475ad17453ee872702a2c98075c2159ec792a1c745275f  MASM.EXE
124a3c800edc16b60f696d35a9dfec798b68b78fe2ca90c5988ea76bdeab1a8a  LINK.EXE
21094b0f11ea0567e4eb71182b2749ada558bc3c9e9e8f6ef7c149a0e67b7c6f  LIB.EXE
c4a6b9870da51719df3cfab4b46f5bc0053ee3a00da10dc7767e966cba0a0c6c  DEBUG.COM
```

## DOSBox commands

From DOSBox:

```dos
mount c /home/agntdrgn/masm
mount t /home/agntdrgn/masm/dos-tools
c:
path t:\
masm source.asm;
link source.obj;
source.exe
debug source.exe
```
