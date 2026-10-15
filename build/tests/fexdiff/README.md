# fexdiff: differential test of x86-64 integer instruction semantics

`fexdiff.c` runs 195 instruction forms (rotates through carry, shifts, double shifts, bit tests and scans,
byte swaps including the 16-bit form, carry arithmetic, flag instructions, conversions, partial registers,
multiply and divide, and a few sequences) on deterministic pseudo-random inputs and prints the result
registers and the arithmetic flags. The inputs are seeded per test name, so every machine runs the same cases.

Build with any x86-64 gcc (WSL: `x86_64-w64-mingw32-gcc -O0 -static -o fexdiff.exe fexdiff.c`). Run it
natively on an x86-64 Windows PC for the reference (`fexdiff-reference-x86.txt` is one), then run the same
EXE under the emulator (Custom… in the app); its output goes to stderr (the session log) and to
`fexdiff-results.txt` beside the EXE. `diff` the two: a differing `T` line names the instruction and the
inputs the emulator gets wrong, a differing `H` line a test whose later (unprinted) cases differ.
