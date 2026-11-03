This is the most advanced program so far because it combines **string scanning, syntax validation, precedence, associativity, a manual operator stack, and output buffering**. 🔥

The goal is to convert an expression like:

```text
12 + 3 * 4
```

into postfix:

```text
12 3 4 * +
```

The algorithm used is essentially the **operator-stack / shunting-yard idea**.

## 1. First, what is postfix?

In normal infix notation:

```text
A + B
```

the operator is between operands.

In postfix:

```text
A B +
```

the operator comes after its operands.

For:

```text
2 + 3 * 4
```

multiplication has higher precedence, so postfix becomes:

```text
2 3 4 * +
```

This postfix form no longer needs precedence rules during evaluation.

---

## 2. Overall strategy

The program scans the infix expression from left to right.

It keeps two main things:

```text
POSTFIX_BUFFER
    → final output

OPERATOR_STACK
    → temporarily holds operators and '('
```

Conceptually:

```text
number
    → immediately put in output

operator
    → possibly pop stronger operators first,
      then push current operator

(
    → push

)
    → pop operators until '('
```

That is the heart of the program.

---

# 3. Important data variables

```asm
INPUT_LENGTH DW 0
INPUT_DATA DB MAX_INPUT+1 DUP (0)
```

These hold the typed infix expression.

For example:

```text
12+3*4
```

might be stored as:

```text
'1' '2' '+' '3' '*' '4' 00H
```

and:

```text
INPUT_LENGTH = 6
```

---

## 4. Postfix output buffer

```asm
OUTPUT_LENGTH  DW 0
POSTFIX_BUFFER DB MAX_OUTPUT DUP ('$')
```

`OUTPUT_LENGTH` tells how many characters have been written.

For:

```text
12 3 4 * +
```

the buffer gradually becomes:

```text
1
12
12 
12 3
12 3 
12 3 4
...
```

---

## 5. Operator stack

```asm
OP_TOP         DB 0
OPERATOR_STACK DB MAX_INPUT DUP (0)
```

This is not the CPU stack.

It is a **custom stack stored in memory**.

Important distinction:

```text
PUSH AX / POP AX
→ CPU stack using SS:SP

OPERATOR_STACK
→ programmer-created array acting as a stack
```

`OP_TOP` tells how many operators are currently stored.

Initially:

```text
OP_TOP = 0
```

meaning empty.

---

# 6. How this custom stack works

Suppose:

```text
OP_TOP = 0
```

To push `'+'`:

```asm
MOV BL, OP_TOP
MOV OPERATOR_STACK[BX], '+'
INC OP_TOP
```

Result:

```text
OPERATOR_STACK[0] = '+'
OP_TOP = 1
```

If `'*'` is pushed next:

```text
OPERATOR_STACK[0] = '+'
OPERATOR_STACK[1] = '*'
OP_TOP = 2
```

The current top element is therefore at:

```text
OP_TOP - 1
```

This explains code like:

```asm
MOV BL, OP_TOP
DEC BX
MOV AL, OPERATOR_STACK[BX]
```

---

# 7. `EXPECT_OPERAND`

This variable is very important:

```asm
EXPECT_OPERAND DB 1
```

It tracks what kind of token is legally allowed next.

```text
EXPECT_OPERAND = 1
→ program currently expects a number or '('

EXPECT_OPERAND = 0
→ program currently expects an operator or ')'
```

This is how the code catches invalid expressions.

For example:

```text
2 + * 3
```

After reading `+`, the program sets:

```text
EXPECT_OPERAND = 1
```

Then it encounters `*`.

But operators are only valid when:

```text
EXPECT_OPERAND = 0
```

so the expression is rejected.

Very useful technique.

---

# 8. Expression-start state

At the beginning:

```asm
MOV OUTPUT_LENGTH, 0
MOV OP_TOP, 0
MOV EXPECT_OPERAND, 1
```

This says:

```text
output empty
operator stack empty
first meaningful thing must be an operand or '('
```

Correct, because something like:

```text
+ 2
```

is invalid since unary `+` is intentionally unsupported.

---

# 9. Input scanning

```asm
LEA SI, INPUT_DATA
MOV CX, INPUT_LENGTH
```

So:

```text
SI → current character
CX = characters remaining
```

This is similar to earlier string programs.

At every step:

```asm
MOV AL, [SI]
```

loads the current character.

---

# 10. End-of-input detection

```asm
CMP CX, 0
JNE CT_HAVE_CHARACTER
JMP CT_END_INPUT
```

If no characters remain, parsing is finished.

Otherwise, process the current character.

---

# 11. Spaces are ignored

```asm
CMP AL, ' '
JE CT_SKIP_SPACE
```

Then:

```asm
CT_SKIP_SPACE:
    INC SI
    DEC CX
    JMP CT_NEXT
```

So these are treated identically:

```text
2+3*4
```

and:

```text
2 + 3 * 4
```

Spaces are simply skipped.

---

# 12. Detecting a number

The code checks:

```asm
CMP AL, '0'
JB CT_NOT_NUMBER
CMP AL, '9'
JA CT_NOT_NUMBER
```

Therefore:

```text
'0' <= AL <= '9'
```

means the current token begins with a number.

If not, it checks for parentheses/operators.

---

# 13. Why check `EXPECT_OPERAND` before a number?

```asm
CMP EXPECT_OPERAND, 1
JE CT_NUMBER
JMP CT_INVALID
```

Suppose input is:

```text
12 34
```

After reading `12`, the parser sets:

```text
EXPECT_OPERAND = 0
```

because it now expects an operator.

Then it sees another number `34`.

That's invalid because there is no operator between them.

So `EXPECT_OPERAND` detects that error.

---

# 14. Multi-digit numbers

This is one of the clever parts:

```asm
CT_NUMBER:
    MOV AL, [SI]
    CALL APPEND_OUTPUT
    JC CT_INVALID
    INC SI
    DEC CX
```

Each digit is copied directly into the postfix output.

For:

```text
123
```

it appends:

```text
'1'
'2'
'3'
```

without treating them as three separate operands.

---

# 15. Continue while digits remain

After appending one digit:

```asm
CMP CX, 0
JE CT_NUMBER_DONE

MOV AL, [SI]
CMP AL, '0'
JB CT_NUMBER_DONE
CMP AL, '9'
JBE CT_NUMBER
```

If the next character is also a digit, control jumps back to:

```asm
CT_NUMBER
```

So:

```text
12345
```

is handled as one complete integer token.

---

# 16. Why append a space after a number?

```asm
CT_NUMBER_DONE:
    MOV AL, ' '
    CALL APPEND_OUTPUT
```

Because postfix needs token separation.

Without spaces:

```text
12 3 +
```

would become:

```text
123+
```

which is ambiguous.

Is that:

```text
12 3 +
```

or:

```text
1 23 +
```

?

Spaces make operands unambiguous.

---

# 17. After a number

```asm
MOV EXPECT_OPERAND, 0
```

means:

> We have just read an operand, so next we expect an operator or `)`.

For example:

```text
12 + ...
```

is valid.

But:

```text
12 34
```

is not.

---

# 18. Recognizing other tokens

If it's not a digit:

```asm
CT_NOT_NUMBER:
    CMP AL, '('
    JE CT_OPEN_PAREN
    CMP AL, ')'
    JE CT_CLOSE_PAREN
    CMP AL, '+'
    JE CT_OPERATOR
    CMP AL, '-'
    JE CT_OPERATOR
    CMP AL, '*'
    JE CT_OPERATOR
    CMP AL, '/'
    JE CT_OPERATOR
    CMP AL, '^'
    JE CT_OPERATOR
    JMP CT_INVALID
```

Anything else is rejected.

So variables such as:

```text
A+B
```

are intentionally unsupported.

---

# 19. Opening parenthesis

For `'('`:

```asm
CMP EXPECT_OPERAND, 1
JE CT_PUSH_OPEN
JMP CT_INVALID
```

An opening parenthesis is only valid when an operand is expected.

Examples:

```text
2 * (3 + 4)
```

valid.

But:

```text
2(3+4)
```

invalid, because implicit multiplication isn't supported.

After `2`, the parser expects an operator, not `'('`.

---

# 20. Pushing `'('`

```asm
XOR BX, BX
MOV BL, OP_TOP
CMP BX, MAX_INPUT
JAE CT_INVALID
MOV OPERATOR_STACK[BX], '('
INC OP_TOP
```

This pushes `'('` onto the custom operator stack.

Suppose stack was:

```text
+
*
```

Then after pushing `'('`:

```text
+
*
(
```

The parenthesis acts as a barrier.

Operators below it must not be popped because of operators inside the parentheses.

---

# 21. Closing parenthesis

When `')'` appears:

```asm
CMP EXPECT_OPERAND, 0
JE CT_CLOSE_POP
JMP CT_INVALID
```

That means a closing parenthesis must follow something that completed an operand expression.

So:

```text
(2+3)
```

valid.

But:

```text
(2+)
```

invalid because after `+`:

```text
EXPECT_OPERAND = 1
```

and then `)` appears.

Good syntax validation.

---

# 22. What happens on `)`?

The algorithm must pop operators until the matching `'('`.

For example:

```text
2 * (3 + 4)
```

when `)` is reached, stack might contain:

```text
*
(
+
```

It pops:

```text
+
```

to output.

Then finds:

```text
(
```

and discards it.

The `(` itself is never written to postfix.

---

# 23. Code for popping until `(`

```asm
CT_CLOSE_POP:
    CMP OP_TOP, 0
    JE CT_INVALID
```

If stack becomes empty before finding `'('`, parentheses are mismatched.

Example:

```text
2+3)
```

is invalid.

---

## 24. Pop one stack element

```asm
DEC OP_TOP
XOR BX, BX
MOV BL, OP_TOP
MOV AL, OPERATOR_STACK[BX]
```

Suppose:

```text
OP_TOP = 3
```

Stack entries are:

```text
0
1
2 ← top
```

After:

```asm
DEC OP_TOP
```

OP_TOP becomes `2`.

Then:

```asm
MOV AL, OPERATOR_STACK[BX]
```

reads element index 2.

That's a normal stack-pop pattern:

```text
--top
value = stack[top]
```

---

# 25. If popped value is `(`

```asm
CMP AL, '('
JE CT_CLOSE_DONE
```

Matching parenthesis was found.

It is discarded.

Notice:

```text
(
```

does not go to postfix output.

Correct.

---

# 26. Otherwise append operator

```asm
CALL APPEND_OPERATOR
```

For example if:

```text
AL = '*'
```

it appends:

```text
"* "
```

to output.

Then continues popping until `'('`.

---

# 27. Operator processing

This is the heart of infix-to-postfix conversion.

Suppose current character is:

```text
+
-
*
/
^
```

First:

```asm
CMP EXPECT_OPERAND, 0
JE CT_SAVE_OPERATOR
JMP CT_INVALID
```

An operator is only legal after an operand or `)`.

So:

```text
2 + 3
```

valid.

But:

```text
+ 2
```

invalid.

And:

```text
2 ** 3
```

invalid.

---

# 28. Save current operator

```asm
MOV CURRENT_OPERATOR, AL
CALL GET_PRECEDENCE
MOV CURRENT_PRECEDENCE, AH
```

Why save it?

Because AL will later be reused to inspect operators already on the stack.

So:

```text
CURRENT_OPERATOR
```

keeps the original operator safe.

---

# 29. Operator precedence

`GET_PRECEDENCE` returns:

```text
+ - → 1
* / → 2
^   → 3
```

This matches normal arithmetic:

```text
^ highest
* / middle
+ - lowest
```

---

# 30. `GET_PRECEDENCE`

```asm
MOV AH, 1
CMP AL, '+'
JE GP_DONE
CMP AL, '-'
JE GP_DONE
```

So `+` and `-` return 1.

Then:

```asm
MOV AH, 2
CMP AL, '*'
JE GP_DONE
CMP AL, '/'
JE GP_DONE
```

so `*` and `/` return 2.

Otherwise:

```asm
MOV AH, 3
```

Since the caller only gives supported operators, the remaining operator is `^`.

---

# 31. Why precedence matters

Consider:

```text
2 + 3 * 4
```

When `+` appears:

```text
stack = +
```

Then `*` appears.

Current precedence:

```text
* = 2
```

stack top:

```text
+ = 1
```

Since the stack top has lower precedence, do not pop `+`.

Push `*`.

Stack:

```text
+
*
```

At end, pop:

```text
*
+
```

giving:

```text
2 3 4 * +
```

Correct.

---

# 32. Compare current operator with top operator

```asm
CMP OP_TOP, 0
JE CT_PUSH_OPERATOR
```

If stack is empty, simply push the current operator.

Otherwise inspect the top:

```asm
MOV BL, OP_TOP
DEC BX
MOV AL, OPERATOR_STACK[BX]
```

Again:

```text
top element = stack[OP_TOP - 1]
```

---

# 33. Don't compare past `(`

```asm
CMP AL, '('
JE CT_PUSH_OPERATOR
```

If top is `'('`, immediately push the current operator.

Why?

Because the opening parenthesis creates a new precedence context.

Example:

```text
2 * (3 + 4)
```

Even though `*` outside has greater precedence than `+`, it must not interfere with the expression inside parentheses.

---

# 34. Get top operator precedence

```asm
CALL GET_PRECEDENCE
```

Now:

```text
AH = precedence of operator already on stack
```

and:

```text
CURRENT_PRECEDENCE
```

contains the current operator's precedence.

Then:

```asm
CMP AH, CURRENT_PRECEDENCE
JA CT_POP_OPERATOR
JB CT_PUSH_OPERATOR
```

Meaning:

```text
top precedence > current
→ pop top

top precedence < current
→ push current
```

---

# 35. Example: `2 * 3 + 4`

Before `+`:

```text
output = 2 3
stack = *
```

Current operator:

```text
+
precedence = 1
```

Top:

```text
*
precedence = 2
```

Since:

```text
2 > 1
```

the `*` is popped first.

Output:

```text
2 3 *
```

Then `+` is pushed.

Eventually:

```text
2 3 * 4 +
```

Correct.

---

# 36. Equal precedence

If precedence is equal:

```asm
CMP CURRENT_OPERATOR, '^'
JE CT_PUSH_OPERATOR
```

For everything except `^`, equal precedence means pop.

Example:

```text
8 - 3 - 2
```

Subtraction is left-associative:

```text
(8 - 3) - 2
```

So first `-` must be emitted before second `-`.

Postfix:

```text
8 3 - 2 -
```

---

# 37. What is associativity?

Precedence answers:

> Which operator binds more strongly?

Associativity answers:

> What happens when precedence is equal?

For:

```text
8 - 3 - 2
```

`-` is left-associative:

```text
(8 - 3) - 2
```

But exponentiation is commonly right-associative:

```text
2 ^ 3 ^ 4
```

means:

```text
2 ^ (3 ^ 4)
```

not:

```text
(2 ^ 3) ^ 4
```

---

# 38. Why `^` is special

The code says:

```asm
CMP CURRENT_OPERATOR, '^'
JE CT_PUSH_OPERATOR
```

So if current `^` has equal precedence with another `^` already on top, it does **not** pop the previous one.

Example:

```text
2^3^4
```

Processing leads to both `^` operators being stacked.

At end they are popped in reverse order.

Output:

```text
2 3 4 ^ ^
```

which represents:

```text
2 ^ (3 ^ 4)
```

Correct.

---

# 39. Left-associative example: `8/4*2`

`/` and `*` have equal precedence.

Since current operator isn't `^`, top operator is popped.

So:

```text
8 / 4 * 2
```

becomes:

```text
8 4 / 2 *
```

representing:

```text
(8 / 4) * 2
```

Correct.

---

# 40. Pop operator

```asm
CT_POP_OPERATOR:
    DEC OP_TOP
    CALL APPEND_OPERATOR
```

This relies on an important detail.

Before the jump, AL already contains:

```text
the top operator
```

So decrementing `OP_TOP` removes it logically, while AL still holds its value.

Then:

```asm
CALL APPEND_OPERATOR
```

writes it to postfix output.

---

# 41. Push current operator

Eventually:

```asm
CT_PUSH_OPERATOR:
    XOR BX, BX
    MOV BL, OP_TOP
```

gets the next free stack index.

Check capacity:

```asm
CMP BX, MAX_INPUT
JAE CT_INVALID
```

Then:

```asm
MOV AL, CURRENT_OPERATOR
MOV OPERATOR_STACK[BX], AL
INC OP_TOP
```

pushes it.

Finally:

```asm
MOV EXPECT_OPERAND, 1
```

because after an operator, another operand must come next.

---

# 42. End-of-input validation

At end:

```asm
CT_END_INPUT:
    CMP EXPECT_OPERAND, 0
    JE CT_EMPTY_STACK
    JMP CT_INVALID
```

This catches expressions ending with an operator.

Example:

```text
2 + 3 *
```

At end:

```text
EXPECT_OPERAND = 1
```

because `*` demands another operand.

So expression is invalid.

Also catches an empty expression because initially:

```text
EXPECT_OPERAND = 1
```

and no operand is ever read.

---

# 43. Empty the operator stack

If expression ended correctly:

```asm
CT_EMPTY_STACK:
    CMP OP_TOP, 0
    JE CT_FINISH
```

pop all remaining operators.

Example:

```text
2 + 3 * 4
```

stack at end:

```text
+
*
```

pop:

```text
*
+
```

into output.

---

# 44. Unmatched opening parenthesis

During final stack emptying:

```asm
MOV AL, OPERATOR_STACK[BX]
CMP AL, '('
JE CT_INVALID
```

If `'('` remains on the stack, it means there was no matching `)`.

Example:

```text
2 * (3 + 4
```

invalid.

So parentheses are validated in both directions:

```text
extra ')' → stack becomes empty too early

extra '(' → '(' remains at end
```

---

# 45. Finishing the output string

Throughout conversion every token ends with a space.

For example:

```text
12 3 4 * + 
```

Notice the final unwanted space.

So:

```asm
MOV BX, OUTPUT_LENGTH
DEC BX
MOV POSTFIX_BUFFER[BX], '$'
```

replaces the final space with:

```text
$
```

Why `$`?

Because afterward:

```asm
LEA DX, POSTFIX_BUFFER
CALL PRINT_STRING
```

uses DOS function `09H`, which requires a `$`-terminated string.

So:

```text
12 3 4 * + $
```

internally prints as:

```text
12 3 4 * +
```

---

# 46. APPEND_OUTPUT

This is the basic output-buffer helper:

```asm
MOV BX, OUTPUT_LENGTH
```

BX becomes the next free index.

Then:

```asm
CMP BX, MAX_OUTPUT-1
JAE AO_FULL
```

checks whether there's enough space.

Why reserve one byte?

Because a terminator will eventually be needed.

Then:

```asm
MOV POSTFIX_BUFFER[BX], AL
INC OUTPUT_LENGTH
```

is basically:

```c
output[output_length] = character;
output_length++;
```

Very simple.

---

# 47. APPEND_OPERATOR

```asm
CALL APPEND_OUTPUT
```

writes the operator.

Then:

```asm
MOV AL, ' '
CALL APPEND_OUTPUT
```

writes a separator.

So:

```text
+
```

becomes:

```text
"+ "
```

in the output buffer.

---

# 48. READ_EXPRESSION

Unlike previous questions, this program reads one character at a time:

```asm
MOV AH, 01H
INT 21H
```

DOS function:

```text
AH = 01H
```

reads one keyboard character and echoes it.

The program repeats until:

```text
AL = 13
```

where decimal 13 is carriage return, meaning Enter.

---

# 49. Why store one character at a time?

```asm
MOV [DI], AL
INC DI
INC CX
```

Here:

```text
DI → next free input location
CX = number of characters read
```

So typed:

```text
2+3
```

becomes:

```text
INPUT_DATA[0] = '2'
INPUT_DATA[1] = '+'
INPUT_DATA[2] = '3'
```

and:

```text
INPUT_LENGTH = 3
```

---

# 50. Maximum length checking

```asm
CMP CX, MAX_INPUT
JAE RE_TOO_LONG
```

Since:

```text
MAX_INPUT = 80
```

no more than 80 characters are stored.

If exceeded, it continues reading and discarding characters until Enter.

That's important because otherwise leftover keyboard characters could interfere with later input.

---

# 51. Zero termination of input

At successful end:

```asm
MOV BYTE PTR [DI], 0
```

so the input becomes zero-terminated too.

Although conversion primarily uses:

```text
INPUT_LENGTH
```

rather than relying on the zero terminator.

---

# 52. Why use both `CX` and zero termination?

`READ_EXPRESSION` provides both:

```text
INPUT_LENGTH
```

and:

```text
00H terminator
```

The converter chooses explicit length-based scanning:

```asm
MOV CX, INPUT_LENGTH
```

This is robust because it doesn't have to keep checking for zero.

---

# 53. Worked example: `2+3*4`

Initial:

```text
output = empty
stack  = empty
```

Read `2`:

```text
output = 2 
stack  = empty
```

Read `+`:

```text
output = 2 
stack  = +
```

Read `3`:

```text
output = 2 3 
stack  = +
```

Read `*`.

Compare:

```text
* precedence = 2
+ precedence = 1
```

Push `*`:

```text
output = 2 3
stack:
+
*
```

Read `4`:

```text
output = 2 3 4
```

End.

Pop `*`:

```text
output = 2 3 4 *
```

Pop `+`:

```text
output = 2 3 4 * +
```

Final postfix:

```text
2 3 4 * +
```

---

# 54. Parentheses example: `(2+3)*4`

Read `(`:

```text
stack = (
```

Read `2`:

```text
output = 2
```

Read `+`:

```text
stack:
(
+
```

Read `3`:

```text
output = 2 3
```

Read `)`:

Pop `+`:

```text
output = 2 3 +
```

discard `(`.

Then read `*`:

```text
stack = *
```

Read `4`:

```text
output = 2 3 + 4
```

End; pop `*`.

Result:

```text
2 3 + 4 *
```

Correct.

---

# 55. Complex example

Input:

```text
12 + 3 * (4 - 2)
```

Output:

```text
12 3 4 2 - * +
```

You can read postfix as:

```text
4 2 -
→ calculate 4-2

3 ... *
→ multiply by 3

12 ... +
→ add 12
```

No parentheses are needed anymore.

---

# 56. Invalid cases the program catches

The syntax state and stack logic catch many errors:

```text
+2
```

invalid because operator appears when operand expected.

```text
2+
```

invalid because expression ends while operand expected.

```text
2 3
```

invalid because second operand appears without operator.

```text
2**3
```

invalid because second operator appears where operand expected.

```text
(2+3
```

invalid because unmatched `(` remains.

```text
2+3)
```

invalid because `)` cannot find matching `(`.

```text
()
```

invalid because `)` appears while operand expected.

```text
2(3+4)
```

invalid because implicit multiplication isn't supported.

That's actually quite solid validation.

---

# 57. One subtle case with spaces

Because spaces are ignored:

```text
12 34
```

is still invalid.

Why?

After parsing `12`:

```text
EXPECT_OPERAND = 0
```

Space is skipped.

Then `34` starts with a digit, but a new operand isn't allowed.

So it rejects it.

Good design.

---

# 58. Why output can be larger than input

```asm
MAX_INPUT  EQU 80
MAX_OUTPUT EQU 170
```

Why is output much larger?

Because input:

```text
12+34
```

contains:

```text
5 characters
```

but postfix includes spaces:

```text
12 34 +
```

which takes more characters.

Every operand/operator can gain a separator.

So the output buffer needs extra room.

---

# 59. `EQU`

This is another useful MASM directive:

```asm
MAX_INPUT EQU 80
```

`EQU` defines an assembler-time constant.

It is similar conceptually to:

```c
#define MAX_INPUT 80
```

No memory is allocated.

Wherever MASM sees:

```text
MAX_INPUT
```

it substitutes the constant value `80`.

---

# 60. One very important distinction: `DB` vs `EQU`

```asm
OP_TOP DB 0
```

allocates one byte in memory.

But:

```asm
MAX_INPUT EQU 80
```

allocates no runtime memory.

So:

```text
DB/DW
→ variables stored in memory

EQU
→ symbolic constant known to assembler
```

---

# 61. C-like pseudocode of the core algorithm

The converter roughly corresponds to:

```c
for each token in infix {

    if (token is a number) {
        output(number);
    }

    else if (token == '(') {
        push(token);
    }

    else if (token == ')') {
        while (top != '(')
            output(pop());
        pop('(');
    }

    else if (token is operator) {
        while (stack not empty &&
               top != '(' &&
               (precedence(top) > precedence(token) ||
                (precedence(top) == precedence(token) &&
                 token != '^'))) {

            output(pop());
        }

        push(token);
    }
}

while (stack not empty)
    output(pop());
```

That is the entire algorithm in high-level form.

---

# 62. Why the precedence condition looks complicated

This:

```text
precedence(top) > precedence(current)
```

means:

> An earlier stronger operator must execute first.

And:

```text
precedence(top) == precedence(current)
AND current != '^'
```

means:

> Equal-precedence left-associative operators execute left-to-right.

That's the logic behind:

```asm
CMP AH, CURRENT_PRECEDENCE
JA CT_POP_OPERATOR
JB CT_PUSH_OPERATOR

CMP CURRENT_OPERATOR, '^'
JE CT_PUSH_OPERATOR
```

This is probably the most important part of the entire program.

---

# 63. CPU stack versus operator stack

This question uses both kinds of stacks, so don't confuse them.

CPU stack:

```asm
PUSH AX
PUSH BX
...
POP BX
POP AX
```

Used for:

```text
saving registers
procedure calls
temporary values
```

Custom operator stack:

```asm
OPERATOR_STACK DB ...
OP_TOP DB ...
```

Used specifically by the infix-to-postfix algorithm.

Think of it like:

```text
CPU stack
→ hardware-supported stack using SP

operator stack
→ array + manually maintained index
```

---

# 64. New concepts introduced here

The major additions are:

| Concept                        | Purpose                             |
| ------------------------------ | ----------------------------------- |
| `EQU`                          | assembler constant                  |
| custom stack                   | array + top index                   |
| precedence                     | controls operator order             |
| associativity                  | resolves equal precedence           |
| parser state                   | `EXPECT_OPERAND`                    |
| multi-digit tokenization       | group consecutive digits            |
| output buffering               | build string character-by-character |
| syntax validation              | reject malformed expressions        |
| shunting-yard style conversion | infix → postfix                     |

---

# 65. The part you should know best

Do not try to memorize this entire program line-for-line.

The three most important ideas are:

### Number

```text
number found
→ copy every digit to postfix
→ append space
```

### Operator

```text
while top operator should execute before current:
    pop top to postfix

push current operator
```

### Parentheses

```text
'('
→ push

')'
→ pop until '('
→ discard '('
```

If those three rules are clear, the program becomes much easier.

---

# 66. Exam-ready explanation

If asked to explain the algorithm, a strong short answer is:

> The program scans the infix expression from left to right. Operands are copied directly to the postfix output, while operators are temporarily stored in an operator stack. Before pushing an operator, operators with higher precedence, or equal precedence for left-associative operators, are popped to the output. Opening parentheses are pushed onto the stack, while a closing parenthesis causes operators to be popped until the matching opening parenthesis is found. Exponentiation is treated as right-associative. After the input ends, all remaining operators are popped into the postfix expression.

That's the core.

The biggest conceptual upgrade from Question 5 is that you're no longer merely processing data—you are now **parsing a small language**. `EXPECT_OPERAND`, precedence, parentheses, and associativity together form a real miniature expression parser. 🚀
