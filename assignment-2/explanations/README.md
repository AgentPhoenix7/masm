# Assignment 2 — explanations for an 8085 programmer

These guides follow the small, numbered, source-based walkthrough style in
[Assignment 1's explanations](../../assignment-1/explanations/).
Keep the corresponding `.ASM` file open while reading.

| Program | Guide | Main ideas |
| --- | --- | --- |
| [Q1.ASM](../Q1.ASM) | [Password checker](Q1.md) | Hidden BIOS key input, backspace, exact comparison, limited attempts |
| [Q2.ASM](../Q2.ASM) | [DOS shell emulator](Q2.md) | Command parsing, string conventions, directory search, handles, file reads/writes |
| [Q3.ASM](../Q3.ASM) | [FCFS disk scheduling](Q3.md) | Word arrays, absolute distances, arrival-order service, total head movement |
| [Q4.ASM](../Q4.ASM) | [Bubble Sort](Q4.md) | Adjacent comparisons, swaps, nested loops, unsigned word sorting |
| [Q5.ASM](../Q5.ASM) | [Bracket balance checker](Q5.md) | Array-based stack, nesting, underflow, matching, final emptiness |

Each guide includes register/data roles, instruction walkthroughs, worked
examples, 8085 comparisons, pseudocode, source limitations, and an exam recap.
The comparisons transfer familiar ideas without treating the processors or
their surrounding systems as interchangeable.

Suggested reading order is Q1, Q4, Q3, Q5, then Q2: the shell has the most
supporting procedures and introduces real DOS file operations.

The explanations describe the checked-in source. For example, Q2's `DIR`
enumerates real DOS directory entries despite the original question's mock-list
wording, and its `COPY` creates or truncates the destination file. Numeric input
is also constrained by the actual DOS line-buffer sizes; each numeric guide
explains the distinction between checking stored input and rejecting every
character a user attempts to type.

This is documentation, not a report of new assembly or runtime tests.
