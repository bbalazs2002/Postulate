# The Postulate Programming Language — v0 Reference Manual

## About this document

This is the **language reference** for Postulate v0 — a complete
description of the language itself: its lexical structure, types,
expressions, statements, declarations, and semantics. It is written for
people who want to **write** Postulate programs, not for people
building the compiler.

"v0" names the language surface currently implemented in full by
**Hoare**, the project's bootstrap compiler (hand-written x86_64
assembly, living in `Hoare/`). If you want to know *how* Hoare
implements any of this — AST layouts, register conventions, code
generation strategy, the test suites — see the implementation specs in
this same `docs/` directory instead:
[postulate_stage0_spec.md](postulate_stage0_spec.md),
[postulate_stage0_lexer_spec.md](postulate_stage0_lexer_spec.md),
[postulate_stage0_parser_spec.md](postulate_stage0_parser_spec.md),
[postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md),
[postulate_stage0_codegen_spec.md](postulate_stage0_codegen_spec.md).
This document deliberately contains none of that — it describes the
language as a language, independent of any particular compiler.

Postulate is a statically-typed, C-like systems programming language
designed first for **mathematically precise correctness proofs** (Hoare
logic, in the relational-model tradition of Ákos Fóthi's *Introduction
to Programming*) and second for **systems/kernel programming** (no
garbage collector, no hidden runtime cost, explicit memory management).
Every design choice in v0 follows from those two goals before
convenience: state is only introduced where it can be reasoned about
(all declarations at the top of a function body), types are never
silently converted, composite values are never partially initialized,
and evaluation order is always fixed and documented rather than left
unspecified.

Section 10 lists the small number of places where the *current* Hoare
toolchain's behavior falls short of, or has not yet caught up with, the
semantics described normatively in the rest of this document — read
that section before relying on an edge case.

---

## 1. Lexical structure

### 1.1 Source text

Source files use the `.ptl` extension. Source text is currently ASCII
(UTF-8 source support is a planned, not-yet-implemented extension).
Whitespace (spaces, tabs, newlines) separates tokens and is otherwise
insignificant — Postulate has no significant indentation and no
statement-terminating newlines; every statement and declaration ends
with an explicit `;`.

### 1.2 Comments

```postulate
// a line comment, runs to the end of the line

/* a block comment,
   may span multiple lines */
```

Block comments do **not** nest — a block comment ends at the first `*/`
encountered.

### 1.3 Identifiers

```ebnf
identifier ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
```

Must start with a letter; digits and underscores are allowed after
that. **No hyphens** — `a-b` is always the subtraction of `a` and `b`,
never a single three-character identifier; this is a deliberate
avoidance of the maximal-munch ambiguity hyphenated identifiers would
create.

Identifiers for structs, functions, and `extern function`s all share
**one global namespace** — you cannot declare a `struct Point` and a
`function Point(...)` in the same program. Local names (parameters and
`decl`s) share one **per-function** namespace with each other, but are
entirely separate from the global namespace — a local may reuse a
struct's or function's name without conflict.

### 1.4 Keywords

Reserved, cannot be used as identifiers:

```
function struct extern mut const if else while return
true false null
int8 int16 int int32 int64 uint8 uint16 uint uint32 uint64 bool void
```

### 1.5 Literals

**Integer literals** come in two forms:

```ebnf
integer_literal ::= decimal_form | based_form
decimal_form    ::= digit+
based_form      ::= digit+ "n" value_digit+
```

- `decimal_form` is ordinary base-10: `42`, `0`, `16384`.
- `based_form` is `BASEnVALUE` — the base as a decimal number, the
  letter `n`, then the value in that base. Only bases `2`, `8`, `10`,
  and `16` are accepted, and every digit of the value must be valid in
  that base (e.g. `2n2` is invalid — `2` is not a base-2 digit). Value
  digits above 9 use `a`-`f`/`A`-`F`, case-insensitively.

  | Example | Base | Value |
  |---|---|---|
  | `16n1F` | 16 (hex) | 31 |
  | `8n17` | 8 (octal) | 15 |
  | `2n101` | 2 (binary) | 5 |
  | `10n42` | 10 (decimal) | 42 |

  There is deliberately no `0x`/`0b`-style prefix — the explicit base
  number leaves room for the set of supported bases to grow later
  without a grammar change.

An integer literal carries no fixed type of its own (see §3.7,
"Untyped constants") — the same literal `5` can be used wherever an
`int8`, an `int64`, a `uint32`, etc. is expected, as long as its value
fits.

**Boolean literals**: `true`, `false`.

**The null literal**: `null` — valid only where a pointer type is
expected (see §3.7).

There is **no string type, no character type, and no floating-point
type** in v0. Raw byte data is represented as `uint8` arrays (see the
worked example in §9, where `"Hello"` is written out as `{72, 101,
108, 108, 111}`).

### 1.6 Operators and punctuation

```
:=  ==  !=  <  >  <=  >=  &&  ||  !  &  |  ^  <<  >>  + - * /  %
(  )  {  }  [  ]  :  ;  ,  .
```

Note that `:=` is the **only** assignment operator — there is no bare
`=`. `^` is bitwise XOR, not exponentiation (there is no `**` operator
in v0 — see §10). `&`/`|`/`^`/`<<`/`>>` are bitwise; `&&`/`||` are
logical (with short-circuit evaluation, see §3.6); `&` is also the
unary address-of operator and `*` is also the unary dereference
operator (disambiguated by position — prefix-unary vs. infix-binary).

---

## 2. Types

### 2.1 Integer types

| Type | Size | Signed | Range |
|---|---|---|---|
| `int8` | 1 byte | yes | −128 .. 127 |
| `uint8` | 1 byte | no | 0 .. 255 |
| `int16` | 2 bytes | yes | −32768 .. 32767 |
| `uint16` | 2 bytes | no | 0 .. 65535 |
| `int32` | 4 bytes | yes | −2³¹ .. 2³¹−1 |
| `uint32` | 4 bytes | no | 0 .. 2³²−1 |
| `int64` | 8 bytes | yes | −2⁶³ .. 2⁶³−1 |
| `uint64` | 8 bytes | no | 0 .. 2⁶⁴−1 |

`int` is a plain alias for `int16`, and `uint` is a plain alias for
`uint16` — **not** separate types; `int` and `int16` are
interchangeable everywhere, including in type-equality checks.

### 2.2 `bool`

A 1-byte type with exactly two values, `true` and `false`. `bool` is
**not** interchangeable with any integer type — `if (1)` and `x + true`
are both type errors; there is no C-style "any nonzero value is
truthy" rule.

### 2.3 Pointers

`*T` is a pointer to a value of type `T` — always 8 bytes, holding a
raw memory address, regardless of what `T` is or how large it is.

- `&expr` (address-of) produces a `*T` from an lvalue `expr : T`.
- `*expr` (dereference) produces a `T` from a `*T`-typed `expr`, both
  as an rvalue (reads through the pointer) and as an lvalue target
  (`*p := 5;` writes through the pointer).
- **No pointer arithmetic** — `p + 1` is a compile error. The only
  operations on a pointer value are address-of, dereference, and plain
  assignment/comparison of the pointer value itself. (Planned for a
  future language version; see §10.)
- `null` is a valid value of any pointer type (see §3.7).

### 2.4 Arrays

`T[N]` is a fixed-size, contiguous array of exactly `N` elements of
type `T`. `N` must be a literal integer written directly in the type —
there is no way to parameterize an array size by a named constant or
expression.

- Indexing: `arr[i]`, both as an rvalue and as an lvalue target.
  Indices are always some integer type. **There is no runtime
  bounds check** — the only bounds checking is a compile-time check
  that applies exclusively when the index is itself a bare integer
  literal (`arr[10]` against a `T[5]` array is caught at compile time;
  `arr[i]` for a variable `i` is never checked, at compile time or at
  run time). Out-of-bounds access through a computed index is
  undefined behavior — the same "no hidden runtime cost" principle
  that keeps `T[N]` free of any length/capacity header.
- Array element type may be any type, including another array (nested
  arrays, `int32[3][4]`-style via `T[N]` composition) or a struct.

### 2.5 The `*T[N]` / `*(T[N])` distinction

Because `*` and `[N]` can both attach to a base type, `type` resolves
them with a **first-match, PEG-style rule**:

```ebnf
type ::= "*" base_type "[" integer_literal "]"
       | "*" type
       | base_type "[" integer_literal "]"
       | "(" type ")"
       | base_type
```

- **`*T[N]` (no parentheses) means "array of N pointers to `T`"** — an
  `N`-element array whose elements are each `*T`. This is the shorter,
  default form.
- **`*(T[N])` (explicit parentheses) means "a pointer to a single
  N-element array of `T`"** — the rarer shape, and it requires the
  parentheses to get it.

```postulate
mut a : *Node[3];     // array of 3 pointers to Node  (24 bytes: 3 * 8)
mut b : *(Node[3]);   // pointer to a 3-element Node array (8 bytes)
```

### 2.6 Structs

```postulate
struct Point {
  x : int32;
  y : int32;
}
```

A `struct` is a named, ordered collection of fields, each with its own
type. Field access is `.`: `p.x`, both as an rvalue and as an lvalue
target, and chains freely with `[]`/`*` (`values.value.ptrs[3]`,
`(*arr)[i].field`, to arbitrary depth).

- **Layout is packed — there is no padding between fields.** Fields sit
  back-to-back in declaration order; a struct's size is exactly the sum
  of its fields' sizes. (A future language version may switch to
  natural/ABI alignment; v0 deliberately keeps the simplest layout that
  is still correct.)
- A struct field may be of any type — including another struct by
  value, or an array — but **may not (directly or indirectly) contain
  itself by value**, since that would require an already-known, finite
  size that doesn't exist yet. Self-reference is only possible through
  a pointer (`next : *Node;`), because a pointer's size (8 bytes) never
  depends on what it points to.
- A struct value is constructed **exclusively** via a struct literal
  (§3.8) that names every field exactly once — there is no way to
  obtain a struct value with any field left uninitialized (see §7.2).

### 2.7 `void`

`void` exists **only** as a function's return type (`return_type ::=
type | "void"`) — it is not part of the general `type` rule, so nothing
can be declared `void`: not a variable, not a struct field, not a
parameter. A `void` function returns no value and is called purely for
its side effects; the checker rejects using its call result as a value
anywhere (`types_equal` never considers `void` equal to anything,
including itself).

### 2.8 No implicit conversion

**Every operation that involves two typed values requires those values
to be of exactly the same type.** There is no implicit widening,
narrowing, signed/unsigned conversion, or struct/array coercion
anywhere in the language. `int8 + int32` is a compile error, as is
passing an `int16` argument to a `uint16` parameter, or assigning an
`int32` expression into an `int64` local — even though `int16` and
`uint16` have the same size, and even though the value would fit. If
you need a value in a different type, the language currently offers no
conversion operator — that too is future work (see §10).

Type equality (`types_equal`) is **structural**: two struct-typed
values are the same type only if they reference the same struct name;
two array types are the same type only if both their element type and
their element count match; `int` and `int16` (and `uint`/`uint16`)
count as identical types, since they are the same underlying type under
different spellings.

---

## 3. Expressions

### 3.1 Precedence and associativity

From loosest to tightest binding (i.e. evaluated last to first):

| Level (loose → tight) | Operators | Associativity |
|---|---|---|
| `logic_or` | `\|\|` | left |
| `logic_and` | `&&` | left |
| `comparison` | `==` `!=` `<` `>` `<=` `>=` | **not chainable** |
| `bit_or` | `\|` | left |
| `bit_xor` | `^` | left |
| `bit_and` | `&` | left |
| `shift` | `<<` `>>` | left |
| `additive` | `+` `-` | left |
| `multiplicative` | `*` `/` `%` | left |
| `unary` | `!` `-` `*` (deref) `&` (address-of) | right (prefix chain) |
| `postfix` | `[]` `.` `()` | left |

**Bitwise operators bind tighter than comparison** (Python-style, not
C-style) — `e & 1 == 1` means `(e & 1) == 1`, deliberately reversing
the classic C pitfall where the same expression parses as
`e & (1 == 1)`.

**Comparison is not chainable**: `a < b < c` is a syntax error, not
`(a < b) < c` or `a < b && b < c`. Write out the conjunction explicitly
if that's what you mean: `a < b && b < c`.

Parenthesization `( expr )` is always available to override precedence.

### 3.2 Arithmetic operators (`+ - * / %`)

Both operands must be of the same integer type; the result has that
same type. `/` and `%` use signed division/remainder for signed
operand types and unsigned division/remainder for unsigned operand
types. Integer overflow behavior follows two's-complement wraparound
for the operand's width (no overflow trap, no promotion to a wider
type).

Unary `-` (negation) requires an integer-typed operand and returns the
same type. Unary `!` (logical not) requires a `bool` operand and
returns `bool`.

### 3.3 Bitwise and shift operators (`& | ^ << >>`)

Both operands must be of the same integer type; the result has that
same type. `>>` is an arithmetic shift (sign-extending) for signed
operand types and a logical shift (zero-filling) for unsigned operand
types; `<<` is the same bit-shift regardless of signedness.

### 3.4 Comparison operators (`== != < > <= >=`)

Both operands must be of exactly the same type; the result is always
`bool`. `==`/`!=` are symmetric equality/inequality. `< > <= >=` are
ordered comparisons — signed comparison for signed operand types,
unsigned comparison for unsigned operand types.

### 3.5 Logical operators (`&& ||` and unary `!`)

Both operands (for `&&`/`||`) or the one operand (for `!`) must be
`bool`; the result is `bool`.

### 3.6 Short-circuit evaluation

`&&` and `||` **short-circuit**: for `a && b`, `b` is only evaluated if
`a` is `true`; for `a || b`, `b` is only evaluated if `a` is `false`.
This is observable, guaranteed behavior — a right-hand side with a
side effect (e.g. a function call) is skipped entirely when the result
is already determined by the left-hand side.

### 3.7 Untyped constants

`int`, `bool`, and `null` literals carry **no type of their own** —
they take on whatever type the surrounding context requires, the same
way untyped numeric constants work in Go. The same literal can be used
in different typed positions:

```postulate
mut a : int8  := 5;      // 5 here is an int8
mut b : int64 := 5;      // the same literal spelling, here an int64
```

The rule that decides which side "anchors" the type in a binary
expression: **whichever operand is not itself a bare literal is
resolved first, and its type becomes the expected type for the other
side.** If both operands are literals, the type expected by the
*enclosing* context (e.g. the declared type of the variable being
initialized) anchors the first operand, which then anchors the second.
`null` behaves the same way, but only ever adopts a pointer type — using
`null` somewhere no pointer type is expected is a type error.

Because literals are untyped, and every other rule in the language
still forbids implicit conversion between two already-typed values,
this is the **only** place where the same source text can produce
different concrete types depending on where it's used.

### 3.8 Struct and array literals

```postulate
struct_literal ::= identifier "{" field_init ("," field_init)* "}"
field_init     ::= identifier ":=" expr

array_literal  ::= "{" expr_list "}"
```

```postulate
Point { x := 1, y := 2 }
{1, 2, 3, 4, 5}
```

- A struct literal must name **every** field of the struct **exactly
  once** — a missing field, an unknown field name, or a repeated field
  is a compile error. There is no partial or default-initialized
  struct value in v0.
- An array literal's element count must match the array type's
  declared size exactly — too few or too many elements is a compile
  error.
- Struct/array literals nest freely (an element/field can itself be a
  struct or array literal) and are usable directly as a `decl`
  initializer, as the right-hand side of an assignment, or as a
  function-call argument.

### 3.9 Function calls

```postulate
postfix_op ::= "[" expr "]" | "." identifier | "(" args? ")"
```

`f(a, b, c)`. The callee must be a bare identifier naming an already
declared `function` or `extern function` — Postulate v0 has no
function pointers or first-class functions, so the callee position
cannot be an arbitrary expression. Argument count and each argument's
type must match the callee's declared parameter list exactly (subject
to the untyped-constant rule in §3.7).

**Argument evaluation order is right to left** — for `f(a(), b())`,
`b()` runs before `a()`. This is deliberate, specified behavior (not
merely "unspecified" the way C leaves it), and applies uniformly to
both `extern function` calls and ordinary user function calls. Write
side-effecting expressions as separate statements before the call if
you need a specific left-to-right order.

**All parameters are passed by value**, including struct- and
array-typed parameters — the callee always receives its own
independent copy; mutating a struct/array parameter inside the callee
is never visible to the caller. There is currently no pass-by-reference
parameter syntax (a pointer parameter, `*T`, is the only way to let a
callee observe or mutate the caller's data — see the worked example's
`increment` function).

A struct/array-typed value may be **returned** from a function exactly
as freely as it can be passed in — the return value is a full,
independent copy of whatever the `return` expression evaluated to.

### 3.10 Lvalues

An **lvalue** is an expression that names a storage location — valid
as an assignment target (§4.2) and as the operand of `&`. Structurally,
an lvalue is any expression built exclusively from identifiers,
`*` (dereference), `[]` (index), and `.` (field access), always
terminating in a bare identifier: `x`, `*p`, `arr[i]`, `s.field`,
`*values.value.ptrs[3]`, `(*arr)[i]`. A literal, a function call
result, or an arithmetic expression is never an lvalue.

A `const`-declared identifier may be read freely but is never a valid
assignment target — except when a `*` dereference occurs before the
base identifier is reached (`*p := 5;` is allowed even if `p` itself is
`const`, since that reassigns the pointee, not the pointer binding
itself; `p := ...;` would not be allowed).

---

## 4. Statements

### 4.1 Declarations (`decl`)

```ebnf
decl ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"
```

```postulate
mut count : int32 := 0;
const limit : int32 := 100;
mut buffer : uint8[64];
```

- **`mut`** introduces a variable that can be freely reassigned later.
  For a scalar or pointer type, initialization is optional (an
  uninitialized `mut` has unspecified/garbage contents until first
  assigned). For a struct or array type, initialization is
  **mandatory**.
- **`const`** introduces a binding that can never be the target of an
  assignment after its declaration. Initialization is **always
  mandatory** for `const`, regardless of type.
- For an array-typed `mut`/`const`, a **single scalar expression**
  (not an array literal) is a valid initializer, and is **broadcast**
  to every element: `mut arr : int32[10] := 0;` sets all 10 elements to
  `0`. An array literal (§3.8) initializes each element individually
  instead.
- **All declarations must appear at the very start of a function
  body**, before any statement — this is enforced grammatically
  (`func_block ::= "{" decl* stmt* "}"`, distinct from the plain
  `block` rule used for `if`/`while` bodies, which permits no `decl`s
  at all). This fixes the complete set of live variables for the whole
  function up front, which is what makes Hoare-triple-style reasoning
  about the function tractable.

### 4.2 Assignment (`assign_stmt`)

```ebnf
assign_pair ::= lvalue ":=" expr
assign_stmt ::= assign_pair ("," assign_pair)* ";"
```

```postulate
x := 5;
a := b, b := a;                 // swap, without a temporary
```

Assignment supports **multiple simultaneous pairs** in one statement,
separated by `,`. Every `lvalue` target within one `assign_stmt` must
be distinct. The semantics are Dijkstra/Hoare **simultaneous**
assignment: every right-hand side is evaluated against the state as it
was **before** the statement executed, and only once all of them have
been evaluated do the assignments take effect, together. This is why
`a := b, b := a;` swaps `a` and `b` rather than leaving both equal to
the original `b` — `b`'s right-hand side (`a`) is read before either
assignment happens.

The right-hand side of any one pair may be a plain expression, a
struct/array literal, a plain-copy source of the same composite type
(`p2 := p1;`), or (for an array-typed target) a scalar broadcast source
— matching the same shapes and rules as a `decl` initializer (§4.1).

### 4.3 `if` / `else`

```ebnf
if_stmt ::= "if" "(" expr ")" block ("else" block)?
block   ::= "{" stmt* "}"
```

```postulate
if (x > 0) {
  y := 1;
} else {
  y := -1;
}
```

The condition must be `bool` (no implicit truthiness conversion —
`if (x)` for an integer `x` is a compile error; write `if (x != 0)`).
Braces are always required, even for a single-statement body — there
is no bodiless `if` form. `else` is optional. Note that `block` (unlike
`func_block`) permits **no declarations** — a new `mut`/`const` cannot
be introduced inside an `if`/`else`/`while` body; declare it in the
enclosing function body instead.

### 4.4 `while`

```ebnf
while_stmt ::= "while" "(" expr ")" block
```

```postulate
while (i < n) {
  i := i + 1;
}
```

Same condition-typing rule as `if` (must be `bool`), and the same
no-declarations-inside-the-body rule. There is no `for`, `do`-`while`,
`break`, or `continue` in v0 — every loop is a `while`, and early exit
from a loop or function is not yet expressible (see §10).

### 4.5 `return`

```ebnf
return_stmt ::= "return" expr? ";"
```

In a `void`-returning function, `return` must appear **without** an
expression (`return;`). In any other function, `return` **must**
include an expression, and that expression's type must match the
function's declared return type exactly (§2.8 — no implicit
conversion, including for a composite return type). **Every execution
path through a non-`void` function must end in a `return`** — falling
off the end of a function that promises a value is not allowed.

### 4.6 Expression statement

```ebnf
expr_stmt ::= expr ";"
```

Any expression, evaluated purely for its side effects, with its result
(if any) discarded — most commonly a function call: `mult(4);`. (A
future compiler version is expected to add a warning, not an error,
for silently discarding a non-`void` call's return value — see §10.)

---

## 5. Declarations

### 5.1 `struct`

```ebnf
struct_decl ::= "struct" identifier "{" field_decl+ "}"
field_decl  ::= identifier ":" type ";"
```

Declares a new struct type (§2.6). At least one field is required — an
empty struct is not valid syntax.

### 5.2 `extern function`

```ebnf
extern_decl ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
```

Declares a function implemented **outside** the Postulate program —
currently, this means a fixed, closed set of Linux syscalls that Hoare
recognizes by name. There is no general foreign-function interface: an
`extern function` under any name other than the ones below, or with a
signature that doesn't match exactly, is a compile error.

| Name | Signature |
|---|---|
| `sys_read` | `(fd: int64, buf: *uint8, count: uint64) : int64` |
| `sys_write` | `(fd: int64, buf: *uint8, count: uint64) : int64` |
| `sys_mmap` | `(addr: uint64, length: uint64, prot: int64, flags: int64, fd: int64, offset: int64) : *uint8` |
| `sys_exit` | `(code: int64) : void` |
| `sys_openat` | `(dirfd: int64, path: *uint8, flags: int64, mode: int64) : int64` |
| `sys_close` | `(fd: int64) : int64` |

`sys_openat`/`sys_close` (Linux syscalls 257/3) were added specifically
to unblock `v1.0.1`'s `#include` (docs/postulate_stage1_v1_0_1_include_design.md)
— Stage 1's own source is v0, and no earlier extern can open a file by
path, only read an already-open descriptor. `path` is `*uint8`, not
`*char`, since v0 has no `char` type at all (the v1 reference's own
§5.2 table for these two names uses `*char`, matching the type that
form will eventually take once `char` exists).

These map directly onto the identically-named Linux x86_64 syscalls.
`extern function` has no body — it is terminated by `;`, and its
declaration exists purely as a typed contract that the compiler
recognizes.

### 5.3 `function`

```ebnf
function ::= "function" identifier "(" params? ")" ":" return_type func_block
params    ::= param ("," param)*
param     ::= identifier ":" type
```

```postulate
function add(a: int32, b: int32) : int32 {
  return a + b;
}
```

A function definition, always with a body (`func_block`, §4.1). There
is currently no way to forward-declare a function separately from its
definition (see §10) — but since the whole program is checked as one
unit before any code is generated, a function may freely call another
function defined later in the same file, and mutual/direct recursion
work without any special declaration order.

---

## 6. Program structure

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function | struct_decl | extern_decl
```

A program is one or more top-level declarations, in any order and any
mix of the three kinds — structs, `extern function`s, and function
definitions all share one flat, ordering-independent top level.

**Exactly one function named `main`, taking zero parameters, must be
present** — this is the program's entry point. `main` must return
`void` or a scalar/integer type (see §10 — this is not yet enforced by
the compiler, but relying on it being enforced is a mistake); if it
returns a value, that value becomes the process's exit code (truncated
to the low 8 bits, per the Linux process exit-code convention —
`return 1002;` and `return 234;` produce the same observable exit
code).

---

## 7. Semantic rules — summary

This section collects rules that are enforced by type/name checking
rather than by the grammar, gathered here for reference (each is also
stated at its point of use above).

### 7.1 Name resolution

- One global namespace shared by struct names, function names, and
  `extern function` names — no two of these three may share a name.
- One local namespace per function, shared by its parameters and its
  `decl`s — no parameter/`decl` or `decl`/`decl` name collision within
  one function. Locals in different functions are entirely
  independent; there is no nested scoping to reason about, because
  `decl`s cannot appear inside `if`/`while` bodies (§4.1).
- A local name is **not** visible to any other function, and does not
  shadow anything — flat, single-level lookup.

### 7.2 No partially-initialized composite values

A struct value only ever comes into existence fully-formed, via a
struct literal naming every field (§3.8) — there is no way to declare
a struct variable, leave some fields unset, and fill them in later. An
array is either broadcast-initialized (every element the same value)
or literal-initialized (every element listed) — same principle, no
partial state.

### 7.3 No implicit type conversion, anywhere

Restated from §2.8 because it is the single rule with the widest
reach: it governs binary operators, assignment, function arguments,
return values, and struct/array literal fields alike. The one
exception is the untyped-constant mechanism for literals (§3.7), which
is not a conversion — an untyped literal never *has* a type to convert
from.

### 7.4 Composite values across function calls

A struct or array value may be used as a function argument and as a
function return value exactly as freely as a scalar can — always by
value, with the callee/caller each getting an independent copy (§3.9).
This includes recursive functions with composite parameters and/or
composite return types, and struct/array values produced by one call
being consumed directly by another (`g(f())`).

---

## 8. Complete grammar (EBNF)

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function | struct_decl | extern_decl

struct_decl    ::= "struct" identifier "{" field_decl+ "}"
field_decl     ::= identifier ":" type ";"

function       ::= "function" identifier "(" params? ")" ":" return_type func_block
return_type    ::= type | "void"
extern_decl    ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
params         ::= param ("," param)*
param          ::= identifier ":" type

func_block     ::= "{" decl* stmt* "}"
block          ::= "{" stmt* "}"
decl           ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"

stmt           ::= assign_stmt | if_stmt | while_stmt | return_stmt | expr_stmt

assign_pair    ::= lvalue ":=" expr
assign_stmt    ::= assign_pair ("," assign_pair)* ";"
lvalue         ::= "*" lvalue | identifier ( "[" expr "]" | "." identifier )*

if_stmt        ::= "if" "(" expr ")" block ("else" block)?
while_stmt     ::= "while" "(" expr ")" block
return_stmt    ::= "return" expr? ";"
expr_stmt      ::= expr ";"

expr           ::= logic_or
logic_or       ::= logic_and ("||" logic_and)*
logic_and      ::= comparison ("&&" comparison)*
comparison     ::= bit_or (("==" | "!=" | "<" | ">" | "<=" | ">=") bit_or)?
bit_or         ::= bit_xor ("|" bit_xor)*
bit_xor        ::= bit_and ("^" bit_and)*
bit_and        ::= shift ("&" shift)*
shift          ::= additive (("<<" | ">>") additive)*
additive       ::= multiplicative (("+" | "-") multiplicative)*
multiplicative ::= unary (("*" | "/" | "%") unary)*
unary          ::= ("!" | "-" | "*" | "&") unary | postfix
postfix        ::= primary postfix_op*
postfix_op     ::= "[" expr "]" | "." identifier | "(" args? ")"
primary        ::= struct_literal | array_literal | identifier | literal | "(" expr ")"
args           ::= expr_list?
expr_list      ::= expr ("," expr)*

struct_literal ::= identifier "{" field_init ("," field_init)* "}"
field_init     ::= identifier ":=" expr

array_literal  ::= "{" expr_list "}"

literal         ::= integer_literal | bool_literal | null_literal
integer_literal ::= decimal_form | based_form
decimal_form    ::= digit+
based_form      ::= digit+ "n" value_digit+
bool_literal    ::= "true" | "false"
null_literal    ::= "null"

base_type      ::= "int8" | "int16" | "int" | "int32" | "int64"
                  | "uint8" | "uint16" | "uint" | "uint32" | "uint64"
                  | "bool" | identifier
type           ::= "*" base_type "[" integer_literal "]"
                  | "*" type
                  | base_type "[" integer_literal "]"
                  | "(" type ")"
                  | base_type

identifier     ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
digit          ::= "0".."9"
value_digit    ::= "0".."9" | "a".."f" | "A".."F"

comment        ::= line_comment | block_comment
line_comment   ::= "//" (any_char_except_newline)* newline
block_comment  ::= "/*" (any_char)* "*/"

keywords       ::= "function" | "struct" | "extern" | "mut" | "const" | "if" | "else" | "while"
                  | "return" | "true" | "false" | "null"
                  | "int8" | "int16" | "int" | "int32" | "int64"
                  | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "bool" | "void"
```

The `type` rule's alternatives apply in order, first match wins — see
§2.5 for what this means for `*T[N]` vs. `*(T[N])`.

---

## 9. Worked example

```postulate
// Syntax showcase for the Postulate language.

extern function sys_write(fd: int64, buf: *uint8, count: uint64) : int64;
extern function sys_exit(code: int64) : void;

struct Node {
  value : int32;
  next  : *Node;
}

struct Pair {
  a : uint8;
  b : uint8;
}

function is_even(n : int32) : bool {
  mut remainder : int32;
  remainder := n % 2;
  return remainder == 0;
}

function power_by_squaring(base : uint64, exp : uint64) : uint64 {
  mut result : uint64 := 1;
  mut b      : uint64 := base;
  mut e      : uint64 := exp;

  while (e > 0) {
    if ((e & 1) == 1) {
      result := result * b;
    }
    b := b * b;
    e := e >> 1;
  }

  return result;
}

function swap_values(x : int32, y : int32) : int32 {
  mut a : int32 := x;
  mut b : int32 := y;

  // Simultaneous assignment: the right-hand sides are evaluated against
  // the original state
  a := b, b := a;

  return a;
}

function make_pair(x : uint8, y : uint8) : Pair {
  return Pair { a := x, b := y };
}

function mult(x : int32) : int32 {
  return x * 2;
}

function increment(p : *int32) : void {
  *p := *p + 1;
}

function main() : int32 {
  // Every declaration goes at the top of the block (func_block ::= decl*
  // stmt*) -- only statements may follow after that.
  const pair : Pair := Pair { a := 8n17, b := 16n1F };
  const total : uint := 16n64;            // uint == uint16

  mut n2 : Node := Node { value := 99, next := null };
  mut n1 : Node := Node { value := 1,  next := &n2 };

  // pointer array: 3 *Node slots, all broadcast to null by default
  mut node_list : *Node[3] := null;

  mut arr : int32[10] := 0;               // every element initialized to 0

  // array_literal: exactly 10 elements, any expr (e.g. a function call) is allowed
  mut arr2 : int32[10] := {1, 2, 3, 4, 5, 6, 7, mult(4), 9, 10};

  mut p   : *int32 := &arr[0];            // just address-of, independent of arr's contents
  mut sum : int32;                        // scalar mut: initializer optional

  mut msg : uint8[5] := {72, 101, 108, 108, 111};   // raw bytes of "Hello" (no string type)

  // --- statements only from here on ---

  node_list[0] := &n1;
  node_list[1] := &n2;

  arr[0] := 5;
  arr[1] := 10;

  sum := *p + arr[1];

  if (is_even(sum)) {
    sum := sum * 2;
  } else {
    sum := sum + 1;
  }

  increment(&sum);   // void function: side effect through a pointer, no return value

  sys_write(1, &msg[0], 5);   // extern function: raw syscall call

  return sum;
}
```

(This program also lives at `samples/Postulate_sample.ptl`.)

---

## 10. Implementation status notes

Everything above is the normative description of Postulate v0. The
following are the specific, known places where the *current* Hoare
toolchain either hasn't caught up to this specification yet, or where
v0 itself deliberately leaves a feature for a later language version.
Both kinds are listed together here so a program that hits one of them
produces a clear diagnostic rather than a confusing surprise.

**Not yet enforced by the current checker** (the language rule above is
still the intended, normative behavior — these are toolchain gaps, not
sanctioned language behavior to rely on):

- `main`'s return type is not checked to be `void`/scalar (§6) — nothing
  currently stops you from writing `function main() : SomeStruct`. This
  is not merely unsupported: the process entry point (`_start`) always
  treats `main`'s return value as sitting in a single register, so a
  composite return type here produces a genuinely broken binary (a
  write through an address that was never set up), not just a wrong
  exit code. Keep `main`'s return type to `void` or scalar/integer.
- A composite-returning function call used **directly and unnamed** as
  a struct/array literal's field or element value (e.g. `Line { start
  := make_point(1, 2), end := ... }`) is rejected with a `codegen
  error` rather than working. The workaround is to bind the call's
  result to a named local first (`mut s : Point := make_point(1, 2);`)
  and use that name in the literal instead — every other composite-call
  pattern (direct decl-init, assignment, `f().field`, passing a call's
  result as another call's argument, recursion) works today.

**Deliberately deferred to a future language version** (not part of v0
at all):

1. **UTF-8 source encoding** — v0 source text is ASCII only.
2. **`**` (exponentiation)**, right-associative, with `^` remaining
   bitwise XOR.
3. **Explicit pass-by-reference parameter syntax** — v0's only way to
   let a callee observe/mutate the caller's data is an explicit pointer
   parameter (`*T`).
4. **Pointer arithmetic** — v0 only allows `&`/`*` on pointers, never
   `p + 1`-style offsetting.
5. **A warning (not error) for a discarded non-`void` call result** —
   e.g. `mult(4);` as a bare statement.
6. **Forward declaration of a function without a body** — every
   `function` in v0 must be defined where it's declared (this does not
   restrict call order or recursion — see §5.3 — it only means there's
   no way to *separately* declare a signature and supply the body
   later).
7. **An explicit type-conversion operator/cast** — v0 has no way to
   convert a value from one type to another; only the untyped-constant
   mechanism (§3.7) lets the same source text take on different
   concrete types.
8. **Early-exit control flow** (a `break`/`continue`/early-`exit`
   construct) — v0's only loop is `while`, run to its natural
   condition-false termination, and the only way out of a function
   early is `return`.
9. **Command-line argument access** for a running Postulate program.
10. **Verification contract syntax** (`requires`/`ensures`/invariants)
    — the language's eventual central feature, intentionally not part
    of v0.
