# The Postulate Programming Language — v1 Reference Manual

## About this document

This is the **language reference** for Postulate v1 — a complete
description of the *planned* language surface: lexical structure,
types, expressions, statements, declarations, and semantics. Like the
v0 reference, it is written for people who want to **write** Postulate
programs, not for people building the compiler.

**v1 is a design document, not yet implemented.** Hoare, the project's
bootstrap compiler, currently implements only
[v0](postulate_v0_language_reference.md) in full. v1 is the target
language surface for **Stage 1** (the self-hosted compiler, written in
Postulate itself, that Hoare's job is to bootstrap) — everything below
is settled *design*, arrived at through a dedicated planning
conversation, not yet built. Where this document changes v0 behavior,
v0's reference remains the accurate description of what Hoare actually
accepts and runs today; this document describes where the language is
going.

Postulate's two founding goals are unchanged from v0: **mathematically
precise correctness proofs** (Hoare logic, in the relational-model
tradition of Ákos Fóthi's *Introduction to Programming*) first, and
**systems/kernel programming** (no garbage collector, no hidden runtime
cost, explicit memory management) second. v1's biggest addition —
verification contracts (§7) — is the language's first real step toward
the first of those two goals; everything else in v1 is either a
practical ergonomic gap v0 left open (pointer arithmetic, casts, early
exit, a module mechanism) or a small, deliberately scoped extension
(`char`, floating point).

Section 11 collects everything **explicitly deferred beyond v1** —
features that were discussed and intentionally not included, most
notably namespaces (planned for v1.1) and any form of *static*
verification (SMT-backed or otherwise — v1's contracts are runtime-only,
see §7.5).

---

## 1. Lexical structure

### 1.1 Source text

Source files use the `.ptl` extension. Source text is **UTF-8**
(upgraded from v0's ASCII-only restriction). This affects only what
*bytes* the lexer accepts — it does not make the language
Unicode-aware: **identifiers and keywords remain ASCII-only** (§1.3
unchanged); UTF-8 multi-byte sequences are only meaningful inside
comments and (once a standard library exists to interpret them, see
§10.1) `char`/pointer-to-`char` data. Whitespace (spaces, tabs,
newlines) separates tokens and is otherwise insignificant — Postulate
has no significant indentation and no statement-terminating newlines;
every statement and declaration ends with an explicit `;`.

### 1.2 Comments

```postulate
// a line comment, runs to the end of the line

/* a block comment,
   may span multiple lines */
```

Block comments do **not** nest — a block comment ends at the first `*/`
encountered. Unchanged from v0.

### 1.3 Identifiers

```ebnf
identifier ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
```

Unchanged from v0: must start with a letter, no hyphens.

Identifiers for structs, functions, and `extern function`s all share
**one namespace within whatever a single file can see** — you cannot
declare a `struct Point` and a `function Point(...)` such that any one
file has both in scope at once, whether declared directly in that file
or brought into view by `#include` (§6.2 defines exactly what a file
can see once `#include` exists, and why this is checked per file rather
than across the whole program). Local names (parameters and `decl`s)
share one **per-function** namespace with each other, but are entirely
separate from this namespace.

**Namespaces** (qualified names, `ns.symbol`-style, to properly scope
names pulled in via `#include`) are explicitly **not** part of v1 — see
§6.2 and §11.

### 1.4 Keywords

**Reserved** — cannot be used as identifiers under any circumstances:

```
function struct extern mut const pure ref operator
if else elseif while return break continue
as sizeof lengthof
true false null
int8 int16 int int32 int64 uint8 uint16 uint uint32 uint64 uintptr
bool void char float32 float64 float ufloat32 ufloat64 ufloat
```

(Additions over v0: `pure`, `ref`, `operator`, `elseif`, `break`,
`continue`, `as`, `sizeof`, `lengthof`, `uintptr`, `char`, `float32`,
`float64`, `float`, `ufloat32`, `ufloat64`, `ufloat`.)

**Contextual keywords** — reserved *only* in the one specific grammar
position each is meaningful in; everywhere else, ordinary identifiers.
This is new in v1, entirely to satisfy one requirement: adding a
verification-contract vocabulary must never take a name away from
ordinary programs. A program is free to declare `function old(...)` or
`mut requires : int32;` — these words are only special in the exact
positions listed in §7.

| Word | Only special... |
|---|---|
| `requires` | as a clause keyword, inside a function's `[ ... ]` contract block (§5.2/§7.1); **or**, bare (no parentheses), as a whole expression atom inside that same function's own `ensures` **or** an `invariant` of one of its `while` loops (§7.6a) |
| `ensures` | as a clause keyword, inside a function's `[ ... ]` contract block |
| `decreases` | as a clause keyword, inside a function's `[ ... ]` contract block, **or** inside a `while` loop's `[ ... ]` clause block |
| `invariant` | as a clause keyword, inside a `while` loop's `[ ... ]` clause block |
| `old` | in the exact call-like form `old(param_name)`, inside an `ensures` **or** `invariant` clause's expression (§7.6/§7.6a) |
| `result` | inside an `ensures` clause's expression, as a bare reference — the one of these that does **not** extend to `invariant`, §7.6 explains why |
| `last` | in the exact call-like form `last(expr)`, inside a `while` loop's `invariant` clause, **or** inside a `decreases` clause (loop or recursive `pure` function alike) (§7.4/§7.6b) |

Anywhere else in the grammar, these seven words lex and parse as plain
`identifier`s — a call `requires(x)` in ordinary code, a variable named
`old`, a struct field named `result`, are all completely unremarkable.
(`requires`/`old` each having two special positions instead of one
doesn't change this: all of them are still narrow and specific, not a
general reservation of the name — see §7.6a for what happens if a
parameter is itself named `requires`.)

### 1.5 Literals

**Integer literals** — unchanged from v0:

```ebnf
integer_literal ::= decimal_form | based_form
decimal_form    ::= digit+
based_form      ::= digit+ "n" value_digit+
```

`based_form` is `BASEnVALUE` (bases 2, 8, 10, 16 only) — see the v0
reference §1.5 for the full table; nothing here changes.

**Floating-point literals** — new in v1:

```ebnf
float_literal ::= digit+ "." digit+ (("e" | "E") ("+" | "-")? digit+)?
```

A decimal point with at least one digit on **both** sides is mandatory
— `5.` and `.5` are not valid spellings, deliberately, to keep the rule
simple and to keep `.` unambiguous with field access. Examples: `3.14`,
`0.0`, `1.5e10`, `2.0E-3`.

**Character literals** — new in v1:

```ebnf
char_literal ::= "'" (char_body | escape_seq) "'"
escape_seq   ::= "\" ("n" | "t" | "r" | "0" | "\" | "'")
```

`'a'`, `'\n'`, `'\t'`, `'\r'`, `'\0'`, `'\\'`, `'\''`. Unlike integer
literals, a character literal has a **fixed** type: `char`, always —
it is not an untyped constant (§3.7 explains why).

**Boolean literals**: `true`, `false`. **The null literal**: `null` —
unchanged from v0.

**There is still no string type** in v1 — see §2.9 for why, and what
takes its place.

### 1.6 Operators and punctuation

```
:=  ==  !=  <  >  <=  >=  &&  ||  !  &  |  ^  <<  >>  + - * /  %  **  _/  as
++  --  :+  :-  :*  :/
(  )  {  }  [  ]  :  ;  ,  .  #
```

New over v0: `**` (exponentiation, §3.2), `_/` (root, §3.2 — an ASCII
digraph; an earlier draft tried `√` and was reverted, see §3.2), `as`
(explicit cast, §3.7a), `++`/`--` (increment/decrement, §4.2a —
statement-only, never usable as part of a larger expression), `:+`/
`:-`/`:*`/`:/` (compound assignment, §4.2 — `:*` in particular looks
like it collides with a pointer type's leading `*`, resolved by
context-sensitive lexing, see §4.2's own note), `#` (only meaningful as
the start of an `#include` directive, §6.2 — not a general-purpose
token).

---

## 2. Types

### 2.1 Integer types

Unchanged from v0:

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

`int` = `int16`, `uint` = `uint16`, interchangeable spellings of the
same type, exactly as in v0.

### 2.2 `bool`

Unchanged from v0: 1 byte, exactly `true`/`false`, never interchangeable
with an integer type *implicitly* — `if (1)` is still a type error. An
**explicit** `as` cast between `bool` and an integer type is now
possible (§3.7a) — that is a deliberate, visible operation, not the
C-style truthiness rule v0 (and v1) both reject.

### 2.3 `char`

New in v1. A 1-byte type representing a single byte of text, always
unsigned (values 0–255). `char` is a **distinct type from `uint8`** —
same size, but they do not type-match structurally (§2.10), and neither
implicitly converts to the other. This is deliberate: a byte count and
a character are different *kinds* of thing, and conflating them is
exactly the kind of silent bug the language's type system exists to
prevent. Convert explicitly with `as` (§3.7a) when you genuinely need
to move between the two.

`char` has literal syntax (§1.5) but **no arithmetic operators of its
own** — `'a' + 1` is a type error, not `'b'`. To do character math, cast
to an integer type, compute, cast back — and since `as`'s operand must
be an lvalue (§3.7a), a literal like `'a'` needs binding to a local
first:

```postulate
mut c : char := 'a';
mut code : uint8 := c as uint8;
code := code + 1;
mut next : char := code as char;   // 'b'
```

**`char` stays exactly 1 byte, even though source text is UTF-8
(§1.1).** This is a deliberate answer to a real tension, not an
oversight: UTF-8 is a *variable-width* encoding — an ASCII character is
one byte, but a non-ASCII Unicode code point can take up to four. A
1-byte `char` can only ever represent one **byte** of UTF-8 text, not
necessarily one full code point — for ASCII text the two coincide, but
for anything outside ASCII, a single character occupies several
consecutive `char`s in memory, exactly the way UTF-8 already works at
the file/OS level. This is the same choice C's `char` and Go's `byte`
make (as opposed to Rust's `char`, which is 4 bytes specifically to
hold one full Unicode scalar value, or Go's separate `rune`) — v1
follows the "byte, not code point" convention, keeping `char` a fixed,
`sizeof`-stable 1 byte, consistent with every other type in this
language having a fixed, `sizeof`-queryable size. A future "one `char`
= one code point" type, if ever added, would be a genuinely different,
wider type (a `rune`-equivalent), not a redefinition of `char` itself.

There is still no dedicated `string` type — see §2.9.

### 2.4 Floating-point types

New in v1: `float32` (IEEE-754 binary32) and `float64` (IEEE-754
binary64), 4 and 8 bytes respectively. `float` is a plain alias for
`float64` — interchangeable spellings of the same type, exactly like
`int`/`int16` (§2.1). Deliberately **not** following `int`/`uint`'s
"alias the smaller width" precedent: `float32`'s ~7 significant decimal
digits are usually too little for real numeric work, and error
accumulates far more noticeably from precision loss in float arithmetic
than from an undersized integer — `float` defaulting to the wider,
safer type avoids a common surprise. (This also matches §3.7's existing
rule that a context-free float literal already defaults to `float64`.)

- Arithmetic: `+ - * /` only — **no `%`** for floats (modulo is an
  integer-only operator in v1). Both operands must be the same float
  type; the result has that same type. Unary `-` is allowed.
- Comparison: `== != < > <= >=`, both operands the same float type,
  result `bool` — with standard IEEE-754 semantics, including that
  `NaN` compares unequal to everything, **including itself**. This is a
  known, accepted tension with the language's verification goals (an
  assertion like `ensures result == result` is not a tautology for a
  float-returning function) — v1 does not attempt to redefine float
  equality to avoid it; contracts over floating-point results should be
  written with that in mind (e.g. bounding an error term, not asserting
  bit-exact equality).
- No bitwise or shift operators apply to any float type.
- No implicit conversion between float widths, between a float type and
  its `ufloat` counterpart (below), or between either and any integer
  type — `as` (§3.7a) converts explicitly in all directions.

**`ufloat32`, `ufloat64`, `ufloat`** (`ufloat` = `ufloat64`, by the same
reasoning as `float` above) — new, distinct types with the *same*
IEEE-754 bit layout as their signed counterparts (there is no separate
unsigned floating-point hardware format to switch to — "unsigned float"
is a language-level guarantee, not a different representation), used
where a value is meant to be non-negative by construction: a `sizeof`
result expressed as a float, a magnitude, a probability. Like `char`
vs. `uint8` (§2.3), `ufloat64` and `float64` do **not** structurally
match and never implicitly convert.

- `ufloat` types support the same operators as their signed
  counterparts (§3.2–§3.4), with one exception: **unary `-` is a
  compile error** on a `ufloat` operand — negating something declared
  non-negative isn't a `ufloat`-typed operation to begin with (contrast
  with signed integer types, where unary `-` is unrestricted even
  though it can wrap; a `ufloat` is meant to statically rule this class
  of mistake out, not just permit-and-hope like an unsigned integer's
  wraparound does).
- A `ufloat` value going negative is otherwise not something v1 proves
  can't happen (no static verification, §7.5, and no *runtime* check
  either — this isn't wired into §2.7b's diagnostic-build pattern, since
  the source would only ever be an explicit `as` cast or arithmetic that
  a `ufloat`'s own missing unary-minus already makes hard to reach by
  accident). Treat `ufloat` primarily as a documentation-and-unary-minus
  safety net, not an airtight guarantee.
- `as` (§3.7a) converts between a float type and its `ufloat`
  counterpart explicitly, same direction rules as `float32`↔`float64`.

### 2.5 Pointers

`*T` is a pointer to a value of type `T`, holding a raw memory address.

**Pointer size is platform-dependent, not fixed at 8 bytes.** This is a
correction from an early v1 draft, which (copying Hoare's own x86_64-only
reality) said pointers are always 8 bytes — wrong for a language whose
stated goal is to eventually target more than one architecture. A
pointer's size is always exactly the target platform's native address
width (8 bytes on x86_64/AArch64, potentially something else on a future
target), queryable like any other type's size via `sizeof` (§2.7a) —
`sizeof(*T)` is well-defined and constant *for a given compiled
program*, just not necessarily the same constant across every target
Postulate might someday compile for. Nothing in the language lets a
program observe a pointer's size as a compile-time literal `8` — use
`sizeof`.

`&expr` / `*expr` (address-of / dereference) are unchanged from v0.

**Pointer arithmetic** — new in v1, replacing v0's flat prohibition:

- `p + n` and `n + p`, for a pointer `p : *T` (`T` not `void`) and any
  integer-typed `n`, produce a `*T` whose address is `n * sizeof(T)`
  bytes past `p`'s. `p - n` moves the same distance backward.
- `p1 - p2`, for two pointers of the **same** `*T`, produces an `int64`
  — the number of `T`-sized elements between them (i.e. the byte
  difference already divided by `sizeof(T)`), matching the usual
  pointer-difference convention. (Arithmetic still requires both
  pointers to share the same pointee type `T`, unlike comparison,
  below — scaling by `sizeof(T)` isn't meaningful otherwise.)
- `p1 + p2` (adding two pointers) is still not meaningful and remains a
  type error.
- `p[i]` is now valid for a pointer-typed `p`, not just a true array —
  defined as sugar for `*(p + i)`. This is what makes `argv[i]` (§6.3)
  usable.
- **Still no bounds checking of any kind** — same "no hidden runtime
  cost" principle as array indexing (v0 §2.4). An out-of-range `p + n`
  or `p[i]` is undefined behavior. As with contracts (§7.5), a
  separately compiled, opt-in diagnostic build can turn this into a
  checked, halt-with-a-diagnostic error instead — see §2.7b.
- Pointer arithmetic does **not** apply to `*void` directly (see §2.6)
  — there is no well-defined element size to scale by. Cast to a
  concrete pointer type first.

**Comparison — `== != < > <= >=` — is valid between *any* two pointer
types**, not just two pointers to the same `T` (unlike arithmetic,
above, and unlike every other comparison in the language, which still
requires exact type equality, §3.4). A memory address is the same
format regardless of what it points to, so comparing a `*int32` against
a `*char`, or either against a `*void`, is well-defined and now
explicitly allowed — an intentional, singular exception to the
same-type comparison rule, justified by what a pointer actually *is*
at the machine level rather than by its declared pointee type. This is
what makes the natural bounds-checked traversal pattern work even when
a loop compares two differently-typed pointers: `while (p < end) { ...;
p := p + 1; }`.

### 2.6 `*void`

New in v1: a pointer that carries no information about what it points
to, matching C's `void*`. Uses: a genuinely type-erased API boundary
(e.g. `sys_mmap`'s return value, §5.2), or the target of a reinterpret
cast (§3.7a) before recovering a concrete pointer type.

- `void` is **not** a general type — same restriction as v0: nothing
  can be declared `void` (no variable, field, parameter, array
  element). The **only** place `void` may appear in a `type` is
  directly after `*`, forming `*void`.
- `*expr` where `expr : *void` is a **type error** — there is no size
  to know how many bytes to load. Cast to a concrete pointer type first,
  then dereference the result: `*(p as *int32)` — see §3.7a for exactly
  how `as` composes with dereference.
- No arithmetic (`+`/`-`/pointer-difference) applies directly to
  `*void` — cast to a concrete pointer type first.
- `==`/`!=`/`<`/`>`/`<=`/`>=` against another `*void` (or `null`) are
  valid, same as any other pointer type.

### 2.7 Arrays

Unchanged from v0 (§2.4–§2.5 there): `T[N]` fixed-size, `N` a literal,
the `*T[N]` vs. `*(T[N])` first-match rule unchanged. Bounds checking:
see §2.7b (this changes from v0's plain "no runtime check" — the
compile-time literal-index check v0 already does is unaffected either
way).

### 2.7a Compile-time size and length: `sizeof`, `lengthof`, `uintptr`

New in v1 — both are reserved keywords (§1.4), and both are resolved
**entirely at compile time**: their argument's *type* is inspected, the
argument itself (if it's an expression, not a bare type) is never
evaluated, exactly like C's `sizeof`.

```ebnf
sizeof_expr   ::= "sizeof" "(" (type | expr) ")"
lengthof_expr ::= "lengthof" "(" (type | expr) ")"
```

- `sizeof(T)` or `sizeof(expr)` — the size of `T` (or `expr`'s static
  type) in bytes, as an untyped integer constant (§3.7 — usable
  anywhere an integer constant would be, adapting to context the same
  way a literal does). This is what "n \* sizeof(T)" means throughout
  §2.5's pointer-arithmetic rules, now spelled out as an actual,
  usable piece of syntax rather than just descriptive prose.
- `lengthof(T)` (`T` an array type) or `lengthof(expr)` (`expr` an
  array-typed expression) — the element count `N` of an array type
  `T[N]`, as an untyped integer constant. A compile error for any
  non-array type — there's no runtime-tracked length to ask a pointer
  or any scalar type for (v1 still has no fat pointers, §2.5).
- **`uintptr`** — a new builtin integer type alias (not a distinct
  type, exactly like `int`/`uint`, §2.1): the unsigned integer type
  guaranteed to be exactly `sizeof(*void)` bytes wide on the target
  platform — i.e. always big enough to hold any pointer's raw address
  without loss, on whichever platform the program is compiled for.
  This replaces the "pointer ↔ `uint64`" line in §3.7a's cast table —
  a fixed `uint64` was only ever correct because Hoare only targets
  x86_64; `uintptr` is the platform-independent way to say the same
  thing. On any platform where a pointer happens to be 8 bytes,
  `uintptr` and `uint64` are the same type, exactly like `int`/`int16`.

### 2.7b Bounds-checking diagnostics

Array indexing and pointer arithmetic/indexing (§2.5/§2.7) still have
**zero built-in runtime bounds checking** in a normally-compiled
program — that principle itself is unchanged. Why this remains
acceptable: the operating system's own page-level memory protection
already stops a process from touching memory outside pages it has
mapped, which catches the most catastrophic class of out-of-bounds
access (a wild pointer landing far outside the process's address
space). What it does **not** catch is the much more common, quieter
case: an index that's out of range for *this* array but still lands
inside some *other* valid, mapped memory the process owns — a
neighboring stack local, a different heap allocation, another struct
field. That's a real, live class of bug no OS-level protection touches,
which is exactly why the stack-canary self-check (Hoare's
`POSTULATE_STACK_CHECK`, documented in `Hoare/README.md`) had to exist
as a *separate* mechanism in the first place.

Following that same, now-established project pattern (also used for
contracts, §7.5): a normally-compiled program pays nothing and checks
nothing; a separately compiled, opt-in diagnostic build additionally
checks every array index against its type's `lengthof` before the
access, halting with a diagnostic on failure. Pointer arithmetic/
indexing has no equivalent check available in v1 — a raw `*T` carries
no bound to check against at all (that would need a fundamentally
different, "fat" pointer representation, which v1 does not introduce);
only true `T[N]` array indexing is checkable this way.

### 2.8 Structs

Unchanged from v0 (§2.6): packed layout, no self-reference by value,
constructed exclusively via a full struct literal.

### 2.9 No `string` type — deliberately

v1 does **not** add a `string` type to the core language. A string —
some pairing of a `*char` and a length, or a NUL-terminated `*char` run
— is exactly the kind of thing a small **standard library**, built on
top of `char`, pointers, pointer arithmetic, and structs, should define
(a plausible future shape: `struct string { data: *char; len: uint; }`)
rather than something the compiler needs to know about specially. This
keeps the core language's job — types, memory layout, verification —
separate from library design. See §10.1.

`main`'s `argv` parameter (§6.3) is therefore typed `**char`, not
`*string` — an array of C-style pointers-to-first-character, exactly
the shape a future `string` library would parse into something nicer.

### 2.10 No implicit conversion, anywhere

Unchanged from v0, and — with `char` and `float32`/`float64` added —
now covering more ground than before: **every operation involving two
typed values still requires those values to be of exactly the same
type**, full stop. `char` and `uint8` do not interconvert. `int32` and
`float32` do not interconvert. `float32` and `float64` do not
interconvert. The **only** relief valve is the new, always-explicit
`as` operator (§3.7a) — v0's complete absence of any conversion
mechanism is the one thing this document changes about §2.8's original
rule text, not the no-implicit-conversion principle itself.

`types_equal` (structural type equality) is unchanged: struct types
match by name, array types match by element type and count, `int`/
`int16` (and `uint`/`uint16`) are identical types. `char` is **not**
structurally equal to any integer type, including `uint8`, despite
sharing its size and signedness.

---

## 3. Expressions

### 3.1 Precedence and associativity

From loosest to tightest binding:

| Level (loose → tight) | Operators | Associativity |
|---|---|---|
| `logic_or` | `\|\|` | left |
| `logic_and` | `&&` | left |
| `comparison` | `==` `!=` `<` `>` `<=` `>=` | **not chainable** |
| `bit_or` | `\|` | left |
| `bit_xor` | `^` | left |
| `bit_and` | `&` | left |
| `shift` | `<<` `>>` | left |
| `additive` | `+` `-` (now also pointer ± integer, §2.5) | left |
| `multiplicative` | `*` `/` `%` | left |
| `exponent` | `**` | **right** |
| `unary` | `!` `-` `*` (deref) `&` (address-of) | right (prefix chain) |
| `postfix` | `[]` `.` `()` | left |

Two new levels over v0: `exponent` (`**`, between multiplicative and
unary), and `as` (§3.7a), which isn't a precedence *level* in the usual
sense — it doesn't sit at one fixed point in the chain the way `**`
does. Instead, `as` attaches directly onto a complete **lvalue** (§3.10)
wherever one appears as an operand, including one built from leading
`*` (dereference) — so it binds tighter than every binary operator
(multiplicative and everything looser than it), but its exact
interaction with the unary prefix chain is a little more specific than
"tighter than unary"; §3.7a spells it out with examples. Everything
else — bitwise-binds-tighter-than-comparison, non-chainable comparison,
parenthesization — is unchanged from v0 §3.1.

### 3.2 Arithmetic operators (`+ - * / % **`)

`+ - * /` unchanged from v0 for integer operands (same integer type on
both sides, two's-complement wraparound, no promotion); now also valid
for same-type float operands (§2.4), and `+`/`-` also valid for pointer
± integer (§2.5). `%` remains integer-only.

**`**` (exponentiation)**, new in v1: both operands the same type —
any integer type, or any of the four float-family types (`float32`/
`float64`/`ufloat32`/`ufloat64`, §2.4) — result that same type,
right-associative — `2 ** 3 ** 2` is `2 ** (3 ** 2)` = `2 ** 9`. For
integer operands the exponent is computed by repeated multiplication
with the same wraparound behavior as `*`; a negative result for an
integer base with a fractional intent doesn't arise, since there is no
implicit float promotion — `x ** y` for integer `x`, `y` is integer
exponentiation only, and (§3.7) an integer literal never silently
becomes a float exponent — see `circle_area` in §12 for what that
means in practice (`radius ** 2.0`, not `radius ** 2`, for a `float64`
`radius`).

Placing `**` **tighter than unary minus** is a deliberate, considered
choice, not an accident: `-2 ** 2` parses as `(-2) ** 2` = `4`, not
Python's `-(2**2)` = `-4`. This keeps `unary` doing what its name says
— binding every prefix operator's operand before anything to its right
gets a chance to — consistent with how v0 already treats `unary` as
tighter than every binary level below it.

Unary `-`/`!` unchanged from v0 (integer/`bool` operand respectively),
except that unary `-` is now additionally valid for a signed-float
operand (`float32`/`float64`) and specifically **not** valid for a
`ufloat` operand (§2.4).

**`_/` (root)**, same precedence and associativity as `**` (they're a
pair): `n _/ x` — the *n*-th root of `x` — for `n`, `x` the same
float-family type, result that same type. Deliberately **not** a
separate operation the checker/codegen has to reason about on its own
— it is defined purely as sugar, always rewritten to a `**` expression
before anything else sees it: `n _/ x` ≡ `x ** (1.0 / n)` (with `1.0`
taken at whichever float-family type `n`/`x` share). `_/` requires a
float-family operand pair for exactly this reason — the desugaring
needs real division, which integer `**` doesn't have a meaningful
equivalent of; to take an integer's root, cast to a float type first.

(An earlier draft used `√`, a Unicode glyph, for this — reverted in
favor of the ASCII `_/` digraph: lexically just as unambiguous, since
`_` is not otherwise a valid operator or identifier-leading character,
§1.3, but typeable on an ordinary keyboard, which the earlier proposal
explicitly flagged as its own weak point.)

### 3.3 Bitwise and shift operators (`& | ^ << >>`)

Unchanged from v0: integer operands only, same type both sides,
`float`/`char`/`bool`/pointer operands are all type errors here.

### 3.4 Comparison operators (`== != < > <= >=`)

Same-type-both-sides, result `bool`, unchanged in shape from v0; now
additionally meaningful for float operands (§2.4, with the NaN caveat).
**Pointer operands are the one exception to "same type"**: any two
pointer types compare against each other, not just matching `*T`s
(§2.5) — because unlike every other type pair, two different pointer
types are still, physically, the same 8-(or however many-)byte address
format.

Struct/array operands remain rejected **at the core-language level** —
this was tightened during v0's own development and stays that way, not
a v1 change. But see §5.4: v1 adds a way to define comparison (and
other) operators for specific struct/array types yourself, meant
precisely for cases like this — the core language still has no
built-in notion of struct/array equality, but a program (or, someday, a
standard library) is no longer stuck without one.

### 3.5 Logical operators (`&& ||` and unary `!`)

Unchanged from v0.

### 3.6 Short-circuit evaluation

Unchanged from v0.

### 3.7 Untyped constants

The untyped-constant mechanism (v0 §3.7) is unchanged for integer,
`bool`, and `null` literals — same anchoring rule, same "whichever
operand isn't a bare literal anchors the other side."

**Float literals are untyped constants too**, but only within the float
family — now all four float-family types (`float32`/`float64`/
`ufloat32`/`ufloat64`, §2.4): a float literal adapts to whichever one
its context requires, the same way an integer literal adapts among the
eight integer types — but a float literal never adapts to an integer
type, and an integer literal never adapts to any float-family type.
`mut f : float32 := 5;` is a type error (`5` is an integer literal;
write `5.0`). With no surrounding context at all, a float literal
defaults to `float64` (not `ufloat64` — §2.4's `float` alias defaults
the same way, and a context-free literal follows the signed default
too, consistent with how a context-free integer literal has never
defaulted to an unsigned type either).

**Character literals are not untyped constants** — a `char_literal`
always has type `char`, full stop, matching §2.3's point that `char`
doesn't blend with anything else.

### 3.7a Explicit conversion (`as`)

New in v1 — v0 had no conversion operator of any kind (v0 §10, item 7).

```ebnf
cast_expr ::= lvalue "as" type
```

`as` looks like a binary operator (`expr as Type`) but its **left
operand must be an lvalue** (§3.10) — not an arbitrary parenthesized
expression, not a call result, not a literal. To cast a computed value,
bind it to a local first: `mut tmp := a + b; tmp as int32;` — you cannot
write `(a + b) as int32` directly. This is a deliberate restriction (not
a grammar accident): every `as` in a program names a concrete,
inspectable storage location changing its declared interpretation,
rather than an anonymous intermediate value doing so — consistent with
the language's general preference for state that can be pointed at and
reasoned about.

Because a dereference (`*p`) is itself an lvalue (§3.10 — `lvalue ::=
"*" lvalue | ...`), `as` attaches to the **entire** lvalue chain,
leading dereferences included, not just to the innermost identifier —
the parser tries to match the longest possible `lvalue` first, and only
then checks for a trailing `as`:

- `x * y as int32` is `x * (y as int32)` — `y` alone is the lvalue here,
  so only `y` gets cast, before the multiplication runs (§3.2).
- `*p as int32` is `(*p) as int32` — `*p` (the dereferenced value) is
  itself the lvalue, so the whole dereference is what gets cast, not
  `p`'s pointer value. This is the useful case: e.g. reading a `*char`
  byte and casting *that value* to `uint8` (see §12's `string_length`).
- To instead reinterpret a *pointer's* type before dereferencing (a
  different, also-common operation — "read these bytes as an `int32`"),
  cast the pointer first and dereference the cast result: `*(p as
  *int32)`. Since `p as *int32` isn't itself an lvalue (a cast
  expression is a value, not a storage location), this specific
  ordering needs the parentheses — `p as *int32` alone, without a
  dereference, is fine without them (see `alloc_int32_buffer` in §12).
- `-x as int32`, `!x as int32`, `&x as int32` are all compile
  errors — `-x`, `!x`, and `&x` are never lvalues (§3.10), so `as` has
  nothing valid to attach to. Bind to a local first if you need this:
  `mut tmp := -x; tmp as int32;`.
- `f() as int32` is a compile error for the same reason — a call result
  is never an lvalue.

**Allowed conversions** — every other combination is a compile error:

| From | To | Notes |
|---|---|---|
| any integer type | any integer type | truncates / sign- or zero-extends as needed |
| integer type | `bool` | nonzero → `true`, zero → `false` |
| `bool` | integer type | `false` → 0, `true` → 1 |
| integer type | `char` | low 8 bits |
| `char` | integer type | zero-extends |
| integer type | any float/`ufloat` type | exact if representable, else nearest |
| any float/`ufloat` type | integer type | truncates toward zero |
| `float32`/`ufloat32` | `float64`/`ufloat64` | exact (widening) |
| `float64`/`ufloat64` | `float32`/`ufloat32` | nearest representable (narrowing, may lose precision) |
| `float32` | `ufloat32`, and back | reinterprets nothing — same bit layout either way (§2.4) |
| `float64` | `ufloat64`, and back | same, at the wider width |
| `*T` | `*U` (any `T`, `U`, including `void`) | reinterprets the address, no representation change |
| `*T` | `uintptr` (§2.7a) | the raw address |
| `uintptr` | `*T` | the raw address, reinterpreted as a pointer |

Notably **not** allowed: pointer to/from any integer type narrower than
`uintptr` (silent address truncation — go through `uintptr` explicitly,
making a further narrowing its own separate, visible cast); `float`
to/from `bool` or `char`; anything to/from a
struct or array type (composite values are never reinterpreted by
`as` — copy/construct them structurally instead, as v0 already
requires).

### 3.8 Struct and array literals

Unchanged from v0 (§3.8 there).

### 3.9 Function calls

Unchanged from v0 (§3.9 there): bare-identifier callee only. `pure`
(§7.2) restricts what a function may do, not how it's called — call
syntax itself doesn't change. **Changed**: "everything passed by
value" is no longer universal — a parameter declared `ref` (§5.3a) is
passed by reference instead, and its call-site argument must be marked
`ref` too (`f(ref x)`) and must be an lvalue. Every parameter *not*
declared `ref` still follows v0's by-value rule exactly, composites
included.

**Changed: argument evaluation order is left-to-right**, not v0's
right-to-left. For `f(a(), b())`, `a()` now runs before `b()`. Still a
*fixed, specified* order, never "unspecified" the way C leaves it (v0
§1's non-negotiable principle carries over unchanged) — only which
order is fixed changes. v0's right-to-left rule existed only because
it was the natural order for Hoare's/the original Stage 1 proof of
concept's push-based calling convention (the last-evaluated argument
ends up closest to the stack pointer); Stage 1's LLVM IR backend
(`v1.0.2`, see
[`postulate_stage1_v1_0_2_llvm_backend_design.md`](postulate_stage1_v1_0_2_llvm_backend_design.md))
removes that mechanism, and with it the only reason to prefer
right-to-left, so `v1` adopts left-to-right — matching source reading
order, the default every C-family language without a specific reason
to do otherwise uses. v0 and Hoare are unaffected and keep
right-to-left, frozen, exactly as documented there; the two languages
are not meant to be reconciled.

### 3.10 Lvalues

Unchanged from v0 (§3.10 there): built exclusively from identifiers,
`*`, `[]`, `.`, always terminating in a bare identifier. `p[i]` for a
pointer `p` (§2.5) is an lvalue by the same structural rule that already
covers array indexing — no new lvalue shape was needed for pointer
indexing.

---

## 4. Statements

### 4.1 Declarations (`decl`)

Unchanged from v0 (§4.1 there).

### 4.2 Assignment (`assign_stmt`)

Dijkstra/Hoare simultaneous assignment, multiple pairs, evaluated
against pre-statement state — unchanged in spirit from v0 (§4.2 there).
**Changed**: an `assign_pair` now picks its operator from five, not
just `:=`:

```ebnf
assign_pair ::= lvalue assign_op expr
assign_op   ::= ":=" | ":+" | ":-" | ":*" | ":/"
```

```postulate
total :+ x;         // total := total + x;
count :- 1;          // count := count - 1;
scale :* 2;           // scale := scale * 2;
average :/ n;          // average := average / n;
```

Each is pure sugar for the corresponding `:=` — `lvalue :+ expr` means
`lvalue := lvalue + expr`, and so on for `:-`/`*`/`/` against `-`/`*`/
`/` respectively — with exactly the operand-typing rule the underlying
operator already has (§3.2): `:+`/`:-` additionally work on a
pointer-typed `lvalue` with an integer-typed `expr` (pointer arithmetic,
§2.5), since that's what plain `+`/`-` already allow there; `:*`/`:/`
never do, since plain `*`/`/` never apply to pointers either.

These compose with §4.2's existing multi-pair, simultaneous-assignment
semantics exactly like a plain `:=` pair would — `total :+ x, x := 0;`
computes `total + x` from the state *before* the statement runs (same
rule as any other pair's right-hand side), then performs both
assignments together.

**Resolution: context-sensitive lexing, not a spacing convention.** `:*`
can look like it collides with a *type* — a pointer type also starts
with `*` (`*T`, §2.5), and a declaration colon is always immediately
followed by a type (`decl`/`param`/`field_decl`, §4.1/§5.1/§5.2). But
the two colons never occur in the same grammatical position: a
type-introducing colon appears only in `decl`/`param`/`field_decl`,
where `assign_op` is never a legal alternative at all; an
`assign_op`-introducing colon appears only at the start of `assign_stmt`,
immediately after a complete `lvalue`, where a bare type is never a
legal alternative either. The parser therefore always knows, before it
asks for the next token, which of the two it is about to see — so the
lexer is handed that one bit of position as a hint (the same "parser
tells the lexer how to read the next token" pattern C++ uses to resolve
`>>` between nested template brackets and the shift operator; not a
novel mechanism). Given that hint, the lexer only ever attempts to merge
`:` with a following `*` into the single `:*` token in assign-op
position; in a type-introducing position it reads `:` and `*` as
separate tokens unconditionally. `mut p:*int32;` and `p :* 2;` are
therefore both unambiguous regardless of spacing — the
`identifier : type` spacing used throughout this document is a
readability convention, not something correctness depends on. §4.2a
below resolves `++`/`--` the same way.

### 4.2a Increment/decrement (`++`/`--`)

```ebnf
incdec_stmt ::= ("++" lvalue | lvalue "++" | "--" lvalue | lvalue "--") ";"
```

New in v1, and deliberately **statement-only** — `++x;`, `x++;`,
`--x;`, `x--;` are never expressions and can never appear nested inside
one, unlike C. Each is pure sugar, expanding before anything else sees
it:

| Spelling | Expands to |
|---|---|
| `++x;` or `x++;` | `x := x + 1;` |
| `--x;` or `x--;` | `x := x - 1;` |

`x` must be an lvalue (§3.10) of an integer type — same operand
restriction `+`/`-` already have (§3.2).

**Resolution: the same context-sensitive lexing as §4.2 — and it fully
resolves this case too, not just narrows it.** `++`/`--` are only ever
legal in one place: `incdec_stmt`, itself only reachable at
statement-start (prefix form) or immediately after a complete `lvalue`
at statement-start (postfix form — the exact position `assign_op`
occupies, §4.2). `incdec_stmt` is never reachable from inside any `expr`
production, since it is a statement, not an expression (above). So the
lexer is only ever told to attempt merging `+`/`-` into `++`/`--` in
those two narrow, statically-known positions; everywhere inside
expression parsing, `+`/`-` are read one character at a time, exactly as
if `++`/`--` did not exist as tokens at all. `x--y` typed as a bare
statement is unambiguously an attempted `incdec_stmt` — and correctly a
syntax error, since `x - -y;` was never a legal statement on its own
either (expression-statements are calls only, §4.7); the identical text
appearing inside an expression, e.g. `total := x--y;` or `f(x--y)`, is
unambiguously `x - -y` (two separate unary/binary minuses — the merge
is simply never attempted there, because RHS-of-`:=` and
argument-position are expression-parsing positions, not statement-start
ones). The same reasoning settles a case that was never even the
original motivation: `total := --x;` (double unary minus, `-(-x)`) is
likewise unambiguous, for exactly the same reason. As in §4.2, spacing
(`x - -y`) stays a readability convention, not a correctness
requirement.

**`total := --x;` is a deliberate divergence from C, worth calling out
on its own.** In C, `total = --x;` means "pre-decrement `x`, then
assign the new value to `total`" — `--` there is a prefix *operator*
with a value (`x` becomes `x − 1`, and that becomes what gets assigned).
In Postulate, `--` is never an expression operator at all — it exists
**only** as its own statement (above), full stop. So `total := --x;`
cannot mean decrement-then-assign; that construct doesn't exist here.
By the resolution just given, `--` inside an expression position is
*always* read as two separate unary-minus tokens, so `total := --x;`
means "assign `x`, negated twice" — i.e. plain `total := x;`. A reader
with C reflexes will misread this line on sight, since nothing marks it
as different from C's pre-decrement beyond knowing this one rule — worth
a comment at any real occurrence, and arguably a reason to prefer
writing `- -x` or `-(-x)` over the more C-decrement-looking `--x`
whenever a double negation is genuinely intended, even though the
grammar accepts either spelling identically.

Because these are statements, not expressions, **prefix and postfix
spell exactly the same thing** — `++x;` and `x++;` are two spellings of
one statement, with no value-producing distinction between them at
all (there's no value to distinguish: a statement doesn't produce one).
This is a deliberate, considered choice, not an oversight — C's prefix
returns the *new* value and postfix the *old* one specifically because
both are usable as sub-expressions, and that distinction is exactly
what stays unavailable here. Allowing `++`/`--` as general expressions
was considered and rejected: every derivation rule in §7.7 (and the
classical Hoare assignment axiom underneath it, `{Q[e/x]} x := e {Q}`)
assumes evaluating an expression never itself changes the state being
reasoned about — true everywhere else in this language, v0 included.
Keeping `++`/`--` statement-only preserves that without exception,
rather than carving out one more place (alongside `requires`/`ensures`/
`invariant`, which would need it excluded explicitly) where evaluating
something can have a side effect.

### 4.3 `if` / `else` / `elseif`

```ebnf
if_stmt ::= "if" "(" expr ")" block ("elseif" "(" expr ")" block)* ("else" block)?
```

`if`/`else` unchanged from v0 (§4.3 there). New in v1: `elseif`,
chaining any number of additional guarded branches without nested
braces —

```postulate
if (x < 0) {
  sign := -1;
} elseif (x == 0) {
  sign := 0;
} else {
  sign := 1;
}
```

is exactly equivalent to (and, per §9's grammar, could always already
be written as) nested `if`/`else`:

```postulate
if (x < 0) {
  sign := -1;
} else {
  if (x == 0) {
    sign := 0;
  } else {
    sign := 1;
  }
}
```

— `elseif` is pure sugar for that nesting, added specifically because
this shape (a chain of mutually exclusive guarded alternatives) is the
same one Dijkstra's guarded-command notation uses, and the relational-
model tradition this language draws on (the "About this document"
preface, and §7's whole premise) reasons about programs in exactly that
vocabulary.

### 4.4 `while`

```ebnf
while_stmt   ::= "while" "(" expr ")" "[" loop_clause+ "]" block
loop_clause  ::= invariant_clause | decreases_clause
```

Same condition-typing rule as v0 (`bool`, no truthiness conversion), and
the same no-declarations-inside-the-body rule. New in v1: every `while`
now carries a bracketed **clause block**, `[ ... ]`, between the
condition and the body, holding **at least one** `invariant` and **at
least one** `decreases` clause (§7.3/§7.4 — `loop_clause+` inside the
brackets, not `loop_clause*`: unlike v1's early design, these are **not
optional**, see §7.1). A `while` with an empty or missing clause block
is a compile error, not a quietly accepted v0-style loop:

```postulate
while (i < 10) [
  invariant: i >= 0 && i <= 10;
  decreases: 10 - i;
] {
  i := i + 1;
}
```

### 4.5 `return`

```ebnf
return_stmt ::= "return" expr? ";"
```

Typing rule unchanged from v0: `void` functions use bare `return;`,
every other function's `return` must include an expression of exactly
the declared return type.

**Changed from v0**: `return` may now appear **anywhere** in a block,
not only as the structurally last statement — early return from a
function is now expressible directly, with no dedicated keyword of its
own (early exit *from a function* is just an early `return` in v1). If
what you actually want is to end the **whole process** immediately —
not just this function — that's a different thing, already expressible
without any new syntax: it's what calling `sys_exit_group` (§5.2's
`extern` whitelist) already does, from anywhere, at any nesting depth,
since it never returns. (`sys_exit` is a related but distinct
primitive, added alongside `sys_clone`/`sys_futex`/`sys_gettid` for
threading, §5.2 — it ends only the calling thread, not the whole
process; use `sys_exit_group` here unless a specific worker thread is
deliberately terminating just itself.) `return`, `break`, `continue`,
and calling `sys_exit_group` are four genuinely different operations
with four different scopes (this function, this loop, this loop, the
whole process, respectively) — v1 doesn't blur them together under one
"exit" word. "Every execution path
must end in a `return`" is still required for a non-`void` function,
but is now a genuine control-flow-reachability property (accounting for
`return`/`break`/`continue` appearing mid-block, inside `if`/`else`
branches, etc.), not the purely structural "last statement" check v0
could get away with.

Code that is unreachable because it follows a `return`, `break`, or
`continue` within the same block is a **compile error**, not a silently
ignored dead branch — consistent with a language whose whole premise is
that every line is meant to be reasoned about. This reachability
analysis knows about `return`/`break`/`continue` specifically —
**not** about calling `sys_exit_group` (which, being an ordinary
`extern` call as far as the checker is concerned, is never treated as
diverging). A non-`void` function that calls `sys_exit_group(...)`
still needs an actual `return` after it to satisfy "every path reaches
a return" (§8.3) — a small, deliberate simplicity trade-off, rather
than teaching the checker that one specific `extern` name never
returns.

### 4.6 `break` / `continue`

New in v1:

```ebnf
break_stmt    ::= "break" ";"
continue_stmt ::= "continue" ";"
```

`break` exits the nearest enclosing `while` immediately; `continue`
skips the rest of the current iteration and jumps straight to the
nearest enclosing `while`'s condition re-check. Both are compile errors
outside any `while`. (v0 had neither — every loop ran to its
condition's natural falsification, v0 §10 item 8.)

**Compilation strategy, specified deliberately** (this is unusual for
a language reference to pin down — normally "how" is left to the
implementation, but this specific choice matters for how a `while`'s
`invariant`/`decreases` clauses, §7.3/§7.4, reason about the loop, so
it's specified here rather than left open): `break` does **not**
compile to a jump out of the loop. It compiles to setting a hidden
boolean flag and skipping the remainder of the current iteration; the
loop's own condition is then implicitly widened to `original_condition
&& !that_flag`. `continue` works the same way, one level narrower —
skipping the remainder of the current iteration without setting the
loop-ending flag. The **observable behavior** is identical to a jump
either way (§4.4's guarantees hold regardless) — what changes is that a
`while`'s control flow, `break`/`continue` included, stays entirely
*structured* (nested ifs and a widened condition), never introducing
anything jump-like underneath. This keeps a loop's `invariant` provable
by ordinary structured-programming reasoning, the same way it would be
without `break`/`continue` at all, rather than needing a separate proof
rule for a jump that exits a loop from the middle of its body.

### 4.7 Expression statement

Unchanged in shape from v0 (§4.6 there): `expr ";"`. **New**: the
compiler now emits a **warning** (not an error — the program still
compiles and runs) when a non-`void` function call's result is silently
discarded as a bare statement, e.g. `mult(4);`. This was v0 §10 item 5,
now realized.

---

## 5. Declarations

### 5.1 `struct`

Unchanged from v0 (§5.1 there).

### 5.2 `function` — unified signature grammar

**Changed from v0**: every function-shaped declaration now uses the
`function` keyword uniformly, whether or not it has a body:

```ebnf
function_decl   ::= ("pure")? "function" identifier "(" params? ")" ":" return_type
                     contract_block? (func_block | ";")
contract_block  ::= "[" contract_clause+ "]"
extern_decl     ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
contract_clause ::= requires_clause | ensures_clause | decreases_clause
params          ::= param ("," param)*
param           ::= ("ref")? identifier ":" type
```

**Changed again since the first v1 draft**: contract clauses are no
longer bare lines sitting between the return type and the body — they
are grouped inside a bracketed **contract block**, `[ ... ]`, and each
clause line now reads `keyword: expr;` (a colon after the keyword,
mirroring a `param`'s own `identifier: type`, and a mandatory `;` on
every clause, including the last one before the closing `]`) — see
§7.1 for the clause grammar itself.

`contract_block?` stays optional *at the grammar level* — a function
with both a forward declaration and a definition needs the freedom to
put its one contract block on only one of the two, below. Whether
enough clauses exist *somewhere* for a given function is a semantic
rule, checked once per function rather than once per production — see
§7.1.

Three shapes fall out of this one rule:

```postulate
function add(a: int32, b: int32) : int32 [        // definition (has a body)
  requires: true;
  ensures: result == a + b;
] {
  return a + b;
}

function multiply(a: int32, b: int32) : int32 [   // forward declaration (no body) --
  requires: true;                                   // clauses go here, NOT repeated
  ensures: result == a * b;                         // on the eventual definition
];

pure function square(x: int32) : int32 [             // pure definition
  requires: true;
  ensures: result >= 0;
] {
  return x * x;
}
```

A **forward declaration** (no body, terminated by `;` instead of a
`func_block` — note the resulting `];` right after the closing bracket
in `multiply` above: the `]` closes the contract block, the `;` is the
`function_decl` production's own terminator, same as any other
`func_block`-less declaration) may carry a contract block itself —
useful once `#include` (§6.2) lets a signature live in one file and its
definition in another. If a function has both a forward declaration and
a definition, **the contract block is written on exactly one of the
two** (whichever came first) — repeating it on the other, even
identically, is a compile error, to avoid the two copies silently
drifting apart.

`extern function` keeps v0's shape (§5.2 there) — always a
`;`-terminated signature, no body, no contract clauses (there is
nothing to check against — foreign/syscall code is trusted, not
verified), naming one fixed, Hoare-recognized set of Linux syscalls.
One signature changes now that `*void` (§2.6) exists — `sys_mmap`'s
return type, more honestly reflecting that mmap hands back
type-erased memory:

| Name | Signature |
|---|---|
| `sys_read` | `(fd: int64, buf: *uint8, count: uint64) : int64` |
| `sys_write` | `(fd: int64, buf: *uint8, count: uint64) : int64` |
| `sys_mmap` | `(addr: uint64, length: uint64, prot: int64, flags: int64, fd: int64, offset: int64) : *void` |
| `sys_munmap` | `(addr: uint64, length: uint64) : int64` |
| `sys_mremap` | `(old_addr: uint64, old_length: uint64, new_length: uint64, flags: int64) : *void` |
| `sys_exit` | `(code: int64) : void` |
| `sys_exit_group` | `(code: int64) : void` |
| `sys_clone` | `(flags: int64, stack: *void, parent_tid: *int32, child_tid: *int32, tls: uint64) : int64` |
| `sys_futex` | `(addr: *uint32, op: int64, val: uint32, timeout: *void, addr2: *uint32, val3: uint32) : int64` |
| `sys_gettid` | `() : int64` |
| `sys_openat` | `(dirfd: int64, path: *char, flags: int64, mode: int64) : int64` |
| `sys_close` | `(fd: int64) : int64` |

(`sys_read`/`sys_write` keep `*uint8` — raw bytes, not necessarily
text; a future `char`-based I/O layer would cast at the boundary, §3.7a.)

`sys_openat`/`sys_close` are also new — added by `v1.0.1`
(docs/postulate_stage1_bootstrap_plan.md) specifically to unblock
`#include` (§6.2): none of the syscalls above can open a file by path,
only read one already-open descriptor (`sys_read`), which is fine for
today's single stdin-fed compiler but not for a preprocessor that has
to open an unbounded, recursively-discovered set of included files
itself. `path` is written `*char` here to match the type this table
will eventually use everywhere once `char` exists — until then, Stage
1's own use of these two externs (still v0 code, no `char` yet) reads
and writes paths as `*uint8`, exactly like `sys_read`/`sys_write`'s own
`buf` parameter above. `openat`, not the older `open`, is deliberate:
`dirfd` is always passed as `AT_FDCWD` (`-100`) since path resolution
itself is done by the caller's own string logic, never left to the
kernel — see the include design doc for the full rationale.

`sys_munmap`/`sys_mremap` are new — the deallocate/reallocate
counterparts to the alloc-only `sys_mmap` v0 already had, closing an
obvious gap (allocate but never free or resize wasn't a complete
story). This stays at exactly the same level `sys_mmap` already
operates at: raw, page-granularity OS memory management, not a real
`malloc`/`free`-style heap allocator with free lists, fragmentation
handling, and arbitrary-size blocks — that remains standard-library
work (§10), built on top of these three syscalls, not something the
core language provides directly.

`sys_exit_group`/`sys_clone`/`sys_futex`/`sys_gettid` are also new —
the minimal raw primitives threading needs, added now so a
thread-safe stdlib (§10.3) can eventually be built on top, exactly the
same relationship `sys_mmap`/`sys_munmap`/`sys_mremap` have to a future
`malloc`/`free`. Two things about this set are worth being precise
about, rather than leaving implicit:

- **`sys_exit` and `sys_exit_group` are not interchangeable once a
  program has more than one thread.** `sys_exit` is the raw Linux
  `exit` syscall — it terminates only the calling thread; if other
  threads are still running, the process keeps going without it.
  `sys_exit_group` terminates every thread in the process at once,
  which is what "end the whole process" (§4.5) actually means once
  `sys_clone` exists. In a program that never calls `sys_clone`, the
  two behave identically (there is only ever one thread to terminate)
  — which is why v0/v1-without-threads could get away with just
  `sys_exit` — but §4.5 (above) points at `sys_exit_group` specifically
  for whole-process termination, since that is the one that stays
  correct once threads are in the picture.
- **`sys_clone` is exposed here as a raw primitive, not as a safe,
  directly callable "spawn a thread" operation** — calling it with a
  `stack` argument that differs from the calling thread's own stack (as
  real thread creation requires, so the two threads don't corrupt each
  other's stack) means the new thread resumes execution on a stack that
  has no return address, no saved frame, nothing on it at all: it
  cannot "return" from the Postulate function that called `sys_clone`
  in the normal calling-convention sense. Real thread creation needs a
  small trampoline — code that arranges for the new stack to contain
  exactly what's needed to jump into a starting function instead of
  attempting to return — which is exactly the kind of thing `_start`
  itself already is in this compiler (hand-written, outside what
  `extern function` alone expresses). A safe `thread_create(fn, arg)`
  is therefore standard-library/runtime work built on top of
  `sys_clone`, `sys_mmap` (for the new stack), and this trampoline —
  not something calling `sys_clone` directly gets you for free, same
  spirit as `sys_mmap` alone not being `malloc`.

The whole-program, checked-before-any-codegen model (v0 §5.3) is
unchanged: forward reference and mutual/direct recursion between
functions defined in the same compiled program work without any
declaration-order requirement, exactly as in v0 — the explicit forward
declaration exists for the `#include` use case, not because ordering
would otherwise matter.

### 5.3 `pure`

New in v1 (§7.2 has the full rule set) — a function-level modifier
placed before `function`. A `pure` function may not call `extern`
functions (directly or transitively) and may not write through any
pointer it's given (directly or transitively) — the only way to have
observable effects in v1 in the first place, since the language has no
mutable global state. A `pure` function that is (directly or mutually)
recursive must carry a `decreases` clause on itself.

`pure` functions are ordinary, freely callable functions — nothing
about calling one is different from calling any other function. The
`pure` marking exists so a function can additionally be referenced from
another function's `requires`/`ensures`/`invariant` (§7.2) — only
`pure` functions may appear there.

### 5.3a `ref` parameters

New in v1 — v0's only way for a callee to observe/mutate the caller's
data was an explicit pointer parameter (v0 §10 item 3); `ref` doesn't
replace that (a pointer parameter is still exactly as valid as before),
it adds a second, higher-level option:

```postulate
function increment(ref x : int32) : void {
  x := x + 1;              // no *, unlike a pointer parameter — ref
}                           // parameters read/write directly

function main() : void {
  mut n : int32 := 5;
  increment(ref n);        // the "ref" at the call site is mandatory,
  // n is now 6            // not optional or inferred
}
```

Every `ref` parameter is **explicit at both ends** — the declaration
(`ref x : T`) and every call site (`f(ref arg)`) — deliberately, so
that whether a given call can mutate its caller's state is always
visible right where the call is written, never something you'd have to
go check the callee's signature to find out. This is why v1 doesn't
adopt C++'s plain `T&` reference parameters, where a call site
(`f(y)`) looks identical whether `y` is passed by value or by
reference — that ambiguity is exactly what "always explicit" here is
avoiding.

- The argument at a `ref` call site must be an lvalue (§3.10) — the
  same restriction `as` (§3.7a) already has, and for the same reason:
  `ref` names a concrete, mutable storage location, not a computed
  value.
- Inside the function body, a `ref` parameter is used exactly like a
  local variable of its declared type — no `*`/`&` needed to read or
  write through it (unlike an explicit pointer parameter, which still
  needs `*p`/`*p := ...`). Whether this is implemented as a hidden
  pointer under the hood is deliberately not specified here — that's
  Stage 1's business, not the language's.
- A `ref` parameter may not also be a composite type passed alongside
  §3.9's by-value copying rule for structs/arrays — `ref` and by-value
  are the two whole options for any parameter, never mixed for the same
  one.
- `pure` functions (§5.3) may not have any `ref` parameter — a `ref`
  parameter exists specifically to let the callee write to caller
  state, which is exactly what `pure` forbids.

### 5.4 Operator overloading

New in v1 — a way to give the operators already defined in §3.2–§3.4
meaning for type combinations the built-in rules leave undefined
(struct/array comparison being the motivating case, §3.4), **not** a
way to invent new operator symbols or override what an operator already
means for a type combination the core language *does* define (`+` for
two `int32`s stays exactly what §3.2 says, always — an overload can
only fill a gap, never shadow existing built-in behavior):

```ebnf
operator_decl ::= "operator" op_symbol "(" param "," param ")" ":" return_type func_block
op_symbol     ::= "==" | "!=" | "<" | ">" | "<=" | ">=" | "+" | "-" | "*" | "/" | "%"
```

```postulate
struct Point { x : int32; y : int32; }

operator ==(a : Point, b : Point) : bool {
  return a.x == b.x && a.y == b.y;
}

function main() : void {
  const p : Point := Point { x := 1, y := 2 };
  const q : Point := Point { x := 1, y := 2 };
  if (p == q) { ... }        // now valid -- resolves to the operator
                              // == defined above
}
```

- Exactly two parameters, matching the operator's own arity (all of
  §3.2–§3.4's operators are binary) — no unary operator overloading in
  v1.
- The checker resolves a use of `==` (or any overloadable operator)
  between two operands of types `A`, `B` by first trying the built-in
  rule (§3.2–§3.4); only if that rule doesn't apply to `A`/`B` does it
  look for a matching `operator` declaration with exactly that
  parameter-type pair. A program cannot define `operator +(a: int32, b:
  int32)` at all — that combination already has a built-in meaning, and
  redefining it is a compile error, not a shadow.
- At most one `operator` declaration may exist for a given (symbol,
  `A`, `B`) triple — no overload resolution beyond that single exact
  match; ambiguity isn't a concern v1 needs to solve, because there is
  never more than one candidate to choose between.
- An `operator` declaration is an ordinary function in every other
  respect — it may be `pure`, may carry `requires`/`ensures` (§7), and
  is checked like any other function body.

This is deliberately scoped narrowly (fixed operator set, exact-match
resolution only, no new symbols) — full user-defined operators with
precedence declarations, or operators over generic/parameterized types,
are exactly the kind of thing that waits for the polymorphism/type-class
work noted in §11, not attempted piecemeal here.

---

## 6. Program structure

### 6.1 Top level

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function_decl | struct_decl | extern_decl
```

Unchanged in shape from v0 — structs, `extern function`s, and
`function`s (now including bodyless forward declarations) share one
flat, order-independent top level.

### 6.2 `#include`

New in v1:

```ebnf
include_directive ::= "#" "include" quoted_path ";"
quoted_path        ::= '"' path_text '"'
```

`path_text` is everything between the two `"` characters, taken
literally as a filesystem path, resolved **relative to the file
containing the `#include`** (not the current working directory, not the
top-level compiled file). The path must already carry its own `.ptl`
extension:

```postulate
#include "./structs.ptl";
#include "../shared/math.ptl";
```

**Terminated by `;`, not by the newline — deliberately, to match every
other statement/declaration in the language** (§1.1: "no
statement-terminating newlines"). An earlier draft of this rule ended
the directive at end-of-line instead, which quietly broke that
principle: it made `#include` the one construct that couldn't share a
physical line with anything else, code that can otherwise always be
compressed onto one line. With `;` as the terminator, `#include`
behaves exactly like any other line in that respect — nothing stops
several directives, or a directive and ordinary code, from sharing one
physical line:

```postulate
#include "./a.ptl"; #include "./b.ptl"; function main() : void { ... }
```

(not idiomatic, just not specially disallowed — the same way cramming
unrelated statements onto one line elsewhere in the language isn't
specially disallowed either). A `//` comment may still follow the `;`,
exactly like after any other statement — nothing `#include`-specific
about that.

**Every `#include` in a file must appear before anything else in that
file except comments and other `#include`s.** This is a genuine,
positional rule, not just a style convention — a `#include` that
follows any real declaration (a `function`/`struct`/`extern function`,
in that same file) is a compile error. This is for readability, plainly
stated as the reason: a file's dependencies are always visible in one
place, at the top, never scattered through the body where they're easy
to miss on a skim. Comments are exempt entirely — a file may open with
a license header, an explanatory block comment, or line comments
between individual `#include`s, none of which count as "something
else" for this rule:

```postulate
// gcd.ptl -- greatest common divisor, specified against gcd_spec.

#include "./contracts.ptl";
// shared Point/Line struct defs
#include "./structs.ptl";

function lnko(x : uint, y : uint) : uint [ ... ] { ... }
```

```postulate
function lnko(x : uint, y : uint) : uint [ ... ] { ... }

#include "./structs.ptl";   // compile error: after lnko's declaration
```

This applies **per file**, independently of `#include`'s own recursive
nature: each file spliced in (the entry file, and every file it
transitively `#include`s) is checked against this rule against its own
content alone — an included file is free to open with its own leading
comments and its own `#include`s before its own first real declaration,
regardless of where in some *other* file's body the `#include` that
pulled it in happens to sit.

**The quotes reserve syntax space, not just delimit a string.**
`#include "path"` is the only legal spelling in v1 — an angle-bracket
form, `#include <path>`, is deliberately left syntactically unclaimed
for a possible future path-resolution mode (a search-path/"system
include" convention, in the spirit of C's distinction between `"..."`
and `<...>`), should one ever be designed. That mode is not designed,
not implemented, and not given any meaning here — `#include <anything>`
is simply not valid v1 syntax today, reserved rather than spent.

`#include` is a **preprocessing** step, resolved before the rest of the
grammar is even relevant, and `;`-termination (above) doesn't change
that: it makes the directive *read* consistently with the rest of the
language, not *behave* like an ordinary parsed statement. One real
consequence follows from no longer being anchored to "alone on its own
line": the preprocessing scan has to recognize v1's comment syntax
(§1.2) well enough to skip over `//` and `/* */` content without
mistaking `#include`-looking text inside a comment for a real directive
— a small, bounded amount of lexical awareness (comment-skipping only,
nothing about identifiers, literals, or any other token shape), not a
step toward `#include` becoming a real grammar production.

**What a `#include` actually grants: everything the named file declares
at its own top level — its `function`s, `extern function`s, and
`struct`s — usable directly, as if declared in your own file.** This
holds fully and unconditionally for any file you name in a `#include`
of your own: nothing about it is partial or requires a further
qualifier.

**What it does not grant, by default: anything reachable only through a
file you did not yourself `#include`.** `#include` is **not transitive
for functions and `extern function`s**: if your file `#include`s
`b.ptl`, and `b.ptl` itself `#include`s `c.ptl`, your file does not
thereby gain the ability to call a function declared in `c.ptl`. Each
file's own `#include` list is a complete, exact statement of which
other files' functions it can use — reading one file tells you
everything it depends on directly, with no need to also chase through
what *that* file depends on in turn.

```postulate
// c.ptl
function helper() : int32 { return 1; }
```

```postulate
// b.ptl
#include "./c.ptl";
function wrapper() : int32 { return helper() + 1; }   // fine: b.ptl includes c.ptl directly
```

```postulate
// a.ptl
#include "./b.ptl";

function main() : int32 {
  return wrapper();   // fine: a.ptl includes b.ptl directly
}

function broken() : int32 {
  return helper();    // compile error: a.ptl never included c.ptl
}
```

`a.ptl` including `b.ptl` gets it `wrapper` (declared directly in
`b.ptl`) but never `helper` (declared in `c.ptl`, which `a.ptl` itself
never named) — even though `helper` is, transitively, part of what
makes `b.ptl` compile at all. If `a.ptl` genuinely needs `helper` too,
it says so itself, the same way `b.ptl` did: its own `#include
"./c.ptl";`.

**One deliberate exception, and only one: a `struct` type mentioned in
something you can already see is visible too.** Unlike a function, a struct has no notion
of an opaque or incomplete form (§5.1) — there is no way to use a value
of a struct type correctly at all without knowing its full field
layout, so making struct visibility follow the same strict,
direct-`#include`-only rule functions follow would force every file to
separately re-`#include` every struct any function it uses happens to
mention, purely to restate something already implied by being able to
call that function in the first place. Extending the example above:

```postulate
// c.ptl
struct Pair { first : int32; second : int32; }
function make_pair() : Pair { return Pair { first := 1, second := 2 }; }
```

```postulate
// b.ptl
#include "./c.ptl";
function wrap_pair() : Pair { return make_pair(); }
```

```postulate
// a.ptl
#include "./b.ptl";

function main() : int32 {
  mut p : Pair := wrap_pair();   // fine: Pair is visible -- wrap_pair,
                                  // which a.ptl does have (b.ptl is its
                                  // own, direct #include), is declared
                                  // to return one
  return p.first;
}

function broken() : Pair {
  return make_pair();   // still a compile error: make_pair itself was
                         // never granted to a.ptl -- only Pair, its
                         // *type*, followed wrap_pair into view
}
```

`Pair` reaches `a.ptl` because `wrap_pair` — a function `a.ptl` does
have — is declared to return one; `make_pair` itself, the function that
actually produces one in `c.ptl`, does not reach `a.ptl`, for the same
reason `helper` didn't above: functions never travel further than the
file that directly `#include`s them.

This does **not** mean struct visibility can chain across several files
the way the rejected, program-wide draft of this rule would have
allowed — `Pair` reaches `a.ptl` because `b.ptl` itself `#include`s
`c.ptl` (owns the dependency directly, not merely received it from
somewhere else); if `b.ptl` had only *consumed* `Pair` through some
other file's own signature, without `#include`ing `c.ptl` itself,
`b.ptl` could not expose `Pair` onward to `a.ptl` at all (the next
paragraph covers exactly why). Struct visibility propagates exactly
**one** `#include` hop past wherever a type is actually owned — never
further, and never by accident of how many files happen to sit between
the true owner and you.

What *does* recurse, independently of the paragraph above, is a
struct's own **field layout** — nothing about naming: a struct field
whose own type is itself another struct, declared in a third, more
distant file, always has its full layout available wherever the outer
struct is used, however many files away that inner declaration lives,
because the compiler needs the actual bytes to generate correct code
regardless of who's allowed to write the inner type's name.

**A struct that only reached you this way may be *consumed*, but never
*authored or re-exposed*.** Consuming covers everything that only needs
to know the type's shape, which propagation already provides: naming
`Pair` in a *local's* type annotation, reading a field off a value you
already have, passing one along as an argument, assigning one whole
value to another (`p2 := p1;`). Two things are different in kind, and
both still require `a.ptl` to `#include "./c.ptl";` itself:

1. **Constructing one.** A struct literal (`Pair { first := ..., second
   := ... }`, §3.8) doesn't consume an existing `Pair`, it *authors* a
   new one, field by field — exactly the kind of dependency `#include`
   exists to make you state yourself.
2. **Putting it in a signature or a field list of your own.** A
   function `a.ptl` itself declares, or a struct `a.ptl` itself
   declares, is something *other* files may in turn `#include` `a.ptl`
   to reach — if `a.ptl` could mention `Pair` there without owning the
   dependency, `a.ptl` would silently become a further, undeclared
   carrier of it, and whoever includes `a.ptl` would inherit `Pair`
   (per the propagation rule) with no `#include "./c.ptl";` anywhere in
   the chain to explain why. This is the same laundering the direct-
   `#include`-only rule for functions was written to prevent in the
   first place, just one level removed — closing it here is what keeps
   that guarantee actually true two hops out, not just one.

```postulate
// a.ptl
#include "./b.ptl";

function also_broken() : int32 {
  mut p : Pair := Pair { first := 5, second := 6 };   // compile error
                                                        // (construction): a.ptl
                                                        // never included c.ptl
  return p.first;
}

function still_broken(p : Pair) : void { }   // compile error (own signature):
                                              // same reason -- a.ptl would
                                              // become a further, silent
                                              // source of Pair for anyone
                                              // who includes a.ptl next

struct Wrapper { inner : Pair; }             // compile error (own field list):
                                              // the same rule, for structs
                                              // instead of functions
```

Only a *local* — never part of anything `a.ptl` exposes to whoever
includes `a.ptl` in turn — may hold a `Pair` on propagated visibility
alone:

```postulate
function fine() : int32 {
  mut p : Pair := wrap_pair();   // fine -- a purely local use, not
                                  // part of a.ptl's own exposed surface
  return p.first;
}
```

`a.ptl` can hold, inspect, and pass along a `Pair`, but authoring one,
or writing it into its own function/struct declarations, is treated
the same as calling `make_pair` directly would have been — a real
dependency on `c.ptl` that has to be declared, not one `a.ptl` gets for
free because `b.ptl` happened to need it too. Struct **layout**
propagation itself stays fully automatic and unrestricted underneath
all of this — a struct's field that is itself another struct from a
third file always has its full layout available wherever the outer
struct is used, regardless of ownership, because the compiler needs
that layout to generate correct code no matter what; what's restricted
above is only which type *names* `a.ptl`'s own source text may write in
a constructing or exposing position, never what layout information the
compiler itself is allowed to know.

**This is a deliberately narrower rule than "everything `#include`-
reachable, however indirectly, shares one namespace,"** which an
earlier draft of this section specified. Two things motivate the
tightening: reading any one file now tells you the *whole* truth about
what it can call, with no need to also read everything its own
`#include`s reach, transitively, just to know whether some name is in
scope — and it is what makes independently compiling and caching each
file practical for an implementation (the work item this unlocks is
`postulate_stage1_bootstrap_plan.md`'s `v1.0.4`; see also §11 item 2,
which this doesn't retract — v1 still doesn't *mandate* any particular
compilation strategy, this rule just stops accidentally ruling the
scalable one out).

**A consequence worth stating plainly: name-collision checking is only
as wide as visibility itself.** Two files that never `#include` each
other, directly or through struct-type propagation, may declare the
same name without either file — or a compiler checking either one on
its own — ever noticing; nothing in the language requires a
whole-program pass that would catch it. If both nonetheless end up
compiled into the same final program (through some third file
`#include`ing both, without either seeing the other), that's exactly
the position two unrelated C translation units defining a same-named
external symbol are in: whether it actually matters depends on whether
an implementation's own link step happens to notice a genuine symbol
clash, not on anything either file's own compilation checked. This is a
deliberate, accepted trade — the alternative (checking name uniqueness
across the whole reachable set, which the earlier, untightened rule got
for free) would reintroduce exactly the whole-program pass this section
exists to make unnecessary.

Two built-in safety properties, both automatic (no manual include-guard
boilerplate needed):

- **Include-once**: a file already spliced in earlier (identified by
  its resolved absolute path) is silently skipped on a repeat
  `#include`, anywhere in the inclusion graph — the equivalent of an
  implicit `#pragma once` on every file.
- **Cycle detection**: a file that `#include`s something already
  *currently being* spliced (not yet finished) — a genuine cycle, not
  just a repeat — is a compile error with a clear diagnostic, rather
  than an infinite preprocessing loop.

There is deliberately **no** macro expansion (`#define`) and no
conditional compilation (`#ifdef`-equivalent) — `#include` is the one
preprocessing feature v1 adds, kept as small as it can be while still
solving the "split a program across files" problem. Further
preprocessor directives beyond `#include` are a plausible later
addition (§11), not part of v1.

**This section defines what a program is allowed to reference, not how
a compiler must build it.** An implementation is free to satisfy the
visibility rule above by literally splicing every reachable file's text
into one buffer and compiling it as a single pass — checking the
narrower per-file visibility rule during name resolution instead of
letting anything anywhere in the merge see everything else — or by
compiling each file independently against just the declarations the
rule grants it, caching each result, and linking the pieces together
the way `Hoare/scripts/build.sh` already links multiple `.o` files
today. Both are conformant; they only have to agree on which programs
are valid and what they compute. §11 item 2 still doesn't make either
strategy a requirement of v1 itself — but the visibility rule above was
deliberately shaped so the scalable strategy is actually achievable by
an implementation that wants it, which the wider, whole-program-flat
version of this rule (an earlier draft) made needlessly hard:
recompiling every reachable file's full text on every build, with no
way to cache a file's own compiled result independently of who else
happens to reach it, is a real, known limitation the wider rule
couldn't avoid. Genuine separate compilation remains a bigger
undertaking than just this naming rule (§11 item 2's own note about
linking, not just name resolution) — this section resolves the
*naming* half, not the whole thing.

### 6.3 `main`

**Changed from v0**: `main` may now be declared in **either** of two
shapes:

```postulate
function main() : return_type { ... }
function main(argv : **char, argc : uint16) : return_type { ... }
```

The zero-parameter form is exactly v0's `main` — for a program that
doesn't need its command-line arguments. The two-parameter form is new:
`argv` is an array (via a plain pointer, §2.5/§2.9) of pointers to the
first `char` of each argument's text; `argc` (`uint16`, chosen over
`uint8` deliberately — the cost difference is negligible, and `uint8`
would impose an arbitrary 255-argument ceiling for no real benefit) is
the number of entries in `argv`. `argv[i]` (pointer indexing, §2.5)
reaches the `i`-th argument's first character; walking that argument's
text is ordinary `*char` pointer arithmetic. There is still no `string`
type (§2.9) — argument text is exposed exactly the way it naturally
exists at the OS boundary, a run of bytes with no built-in length
attached (conventionally NUL-terminated, matching the underlying OS
convention, though v1 itself doesn't enforce that — it's a property of
what the runtime hands `main`, not a language rule).

Any parameter list other than these two exact shapes is a compile
error, same enforcement spirit as v0's "`main` must take zero
parameters" rule.

**Changed from v0 in one more way**: `return_type` must be `void` or an
**atomic type** — an integer type, `bool`, `char`, a float-family type,
or a pointer type; never a struct or array — and this is now a
**compiler-enforced** rule, not just documented, normative advice a
toolchain might not yet check (which is what it was in v0, and remained
in Hoare — see v0 §10's implementation-status note on exactly this
point, and its explanation of the concretely broken binary a composite
`main` return type produces). A non-atomic `main` return type is a
compile error in v1, full stop — the entry-point boundary always knows
how to package an atomic value into a process exit code, and v1 no
longer allows a program to reach codegen with a `main` that would break
that assumption. If non-`void`, the returned value becomes the process
exit code (truncated to 8 bits), same as v0.

---

## 7. Verification contracts

This is v1's central addition — the language's first real step toward
its founding goal of mathematically precise correctness proofs. It is
deliberately scoped **narrowly**: contracts are checked for
well-formedness by the compiler always, but only ever *enforced* — made
to actually catch a violation — by a separately compiled, opt-in
variant of the program (§7.5). There is no static prover, no SMT
solver, and no attempt at one in v1; see §11 for why that's a
deliberate boundary, not an oversight. §7.1–§7.6 specify what a program
writes and what gets checked when; §7.7 gives the formal derivation
rules that are the actual reason those specific checking points are the
correct ones, for anyone who wants the underlying proof theory, not
just the practical rule set.

### 7.1 Clauses

Four contextual keywords (§1.4), each introducing one boolean-valued
clause:

```ebnf
requires_clause  ::= "requires" ":" expr ";"
ensures_clause   ::= "ensures" ":" expr ";"
invariant_clause ::= "invariant" ":" expr ";"
decreases_clause ::= "decreases" ":" expr ";"
```

Clauses are grouped inside a bracketed block, `[ ... ]` — a
`contract_block` after a function's return type (§5.2), or a
`loop_block` after a `while`'s condition (§4.4) — never bare in the
signature/condition position the way an earlier draft had them.

- **`requires`** — a precondition, attached to a function (§5.2). Must
  hold whenever the function is called.
- **`ensures`** — a postcondition, attached to a function. Must hold at
  every point the function returns. May use `old(param)` (§7.6) to
  refer to a parameter's value at entry, and `result` (§7.6) to refer
  to the return value (only for a non-`void` function — using `result`
  in a `void` function's `ensures` is a compile error).
- **`invariant`** — attached to a `while` loop (§4.4). Must hold
  immediately before the loop's condition is first checked, and again
  after every iteration's body finishes. May use `old(param)` (§7.6),
  the bare `requires` reference (§7.6a), and `last(expr)` (§7.6b)
  exactly as `ensures` can — not `result` (§7.3/§7.6).
- **`decreases`** — attached to either a `while` loop or a `pure`
  function (§5.3). An integer-typed expression (the *variant*, or
  termination measure) that must be non-negative and strictly smaller
  on every subsequent iteration/call than it was the time before —
  `last(expr)` (§7.6b) is available here too — the
  classical technique for proving a loop or recursion actually
  terminates.

**Clauses are mandatory, not optional** — a deliberate, considered
change from an earlier v1 draft (which made all four optional, so a
function/loop with none behaved exactly as in v0). Every function (§5.2
— counting its forward declaration and definition together as one unit)
must carry **at least one** `requires` and **at least one** `ensures`
*somewhere* in that unit; every `while` (§4.4) must carry **at least
one** `invariant` and **at least one** `decreases`. A function/loop
with no meaningful constraint still states that explicitly —
`requires: true; ensures: true;` is the honest way to say "nothing is
assumed, nothing beyond termination is promised," not an omission.

The two are enforced at **different levels**, and that difference is
deliberate, not an oversight: a `while`'s clause block is never split
across two locations, so the grammar enforces it directly (§9:
`loop_block ::= "[" loop_clause+ "]"` — `+`, not `*`; a `while` with an
empty or absent clause block is a syntax error, full stop). A
function's `contract_block`, by contrast, is allowed to sit on *either*
its forward declaration or its definition (§5.2), so `contract_block`
is `?` (optional) at each individual production — a function with a
body and no forward declaration always carries its own block, but one
half of a forward-declared/defined pair legitimately carries none.
"At least one `requires` and `ensures` somewhere in the pair" is
therefore a **semantic** rule (§8.1), checked once per function across
both occurrences, not a per-production grammar `+`. Either way, ending
up with no clauses at all — because the block was omitted everywhere
it was allowed to be — is a compile error; the enforcement mechanism
differs, the practical guarantee doesn't.

Two carve-outs, both narrow and already implied by other rules:

- **`extern function`** (§5.2) still takes **no** clauses at all, ever
  — there's nothing to check a syscall's trusted, foreign body against,
  so requiring a clause there would only ever be decorative.
- **`decreases`** is required on a `pure` function only if it's
  (directly or mutually) **recursive** (§5.3/§7.4 — unchanged from the
  original design) — a non-recursive function has nothing to prove
  terminates beyond what "it's not a loop and not recursive" already
  guarantees, so demanding a termination measure for it would be
  meaningless, not merely redundant.

If a function has both a forward declaration and a definition, recall
(§5.2) that clauses live on exactly one of the two — the mandatory
requirement is checked against whichever one actually carries them, not
doubled up.

Multiple clauses of the same kind on one function/loop are still
allowed and conjuncted (logical AND) together — often more readable
than one long `&&`-chain, and mirroring how the original hand-written
sample this design grew out of broke its reasoning into several named
steps (see §12).

### 7.2 `pure` functions and the no-self-reference rule

A contract clause's expression is restricted to what can be *evaluated
without side effects*: literals, parameters, locals it has read access
to, operators, and calls to **`pure`**-marked functions (§5.3) —
calling an ordinary (non-`pure`) function from inside any contract
clause is a compile error.

`pure` itself (§5.3) means: no `extern` calls, no writes through any
pointer, anywhere in the function's own body or anything it calls —
checked transitively. (Postulate has no mutable global state to
restrict separately — parameters and locals are the only state a
function has, and locals can't outlive the function, so this one rule
already rules out every other kind of side effect the language can
express.) A recursive `pure` function must carry a `decreases` clause on
itself, checked as in §7.4.

**A function's own contract clauses may not call that function** —
directly, or transitively through any other `pure` function also
reachable from that clause. This is not a limitation to be worked
around later; it's a basic soundness requirement (you cannot use a
function's own behavior as the specification of its own behavior — that
proves nothing, circularly). The fix is always the same: write a
**separate** `pure` function expressing the property mathematically
(often a direct transcription of the textbook recursive definition —
Euclid's algorithm, in the worked example, §9), and reference *that*
from the real function's `ensures`. The two implementations don't need
to share any code or algorithm — that they agree is exactly the thing
being checked (at runtime, per §7.5) when a program is compiled with
contract checking on.

### 7.3 Loop invariants

An `invariant` clause on a `while` loop is checked (§7.5) at two
points: once before the first condition check, and once after every
execution of the loop body (i.e. immediately before the condition is
re-checked for the next iteration). A loop with multiple `invariant`
clauses checks all of them, both times, conjuncted.

An `invariant`'s expression may also use `old(param)` and the bare
`requires` reference (§7.6/§7.6a), with exactly the same meanings they
have in `ensures`. `old(param)` still names the enclosing *function's*
entry-time value — not "the value at the start of this iteration"; a
loop has no entry-snapshot of its own, only the function does, and that
is the only one `old` ever refers to, regardless of which clause it's
written in. `requires` still expands to the function's own precondition,
evaluated against whatever is current at the checkpoint the invariant
is being checked at (loop entry, or after any iteration) — so
`invariant: requires;` asserts "the function's precondition is still
holding," checked at every loop checkpoint rather than only once at the
end, a more frequently-verified version of the same idea §7.6a shows
for `ensures`.

### 7.4 `decreases` and termination

A `decreases` clause's expression is evaluated at the same points as an
`invariant` (loop) or at every recursive self-call (`pure` function),
and its value is compared against the value it had the *previous* time
it was evaluated in the same loop/call chain: it must be non-negative,
and strictly less than the previous value. The very first evaluation
(before the first iteration, or the outermost call) has nothing to
compare against and only its non-negativity is checked.

The checker already has to remember that "previous value" to do this
comparison at all — `last(expr)` (§7.6b) gives the programmer a name
for exactly that quantity, for any expression, not only `decreases`'s
own. This is *not* a restatement of the rule just given (see §7.6b for
why the two don't collapse into one mechanism), just a related tool
built on the same underlying bookkeeping.

This is a **runtime** check (§7.5), not a proof — a `decreases` clause
that happens to be wrong (doesn't actually decrease on some input) is
only caught if a checked build is actually run on an input that exposes
it, exactly like every other contract clause in v1.

Now that every `while` needs one (§7.1), it's worth naming a real
consequence directly: a loop that scans toward a condition with no
statically-known bound (the classic case: walking a pointer forward
until it happens to hit a NUL terminator, not knowing in advance how
far that is) has no honest decreasing, non-negative measure to offer on
its own — "how much closer am I to done" isn't answerable without
already knowing where "done" is. The fix isn't a special case in the
language; it's the same fix such a loop already needed for its
`invariant` to be meaningful in the first place: introduce an explicit
bound (a maximum length, a known buffer size) and measure distance to
*that*, as §12's `string_length` does. A `decreases` clause you can't
write honestly is frequently a sign the loop itself is trusting an
assumption ("this buffer is NUL-terminated within some reasonable
distance") that was previously implicit and unstated — making that
assumption a real, named parameter is the point, not a workaround.

### 7.5 Checking model: runtime assertions, not static proof

v1 deliberately does **not** attempt to statically prove any contract
clause true. Every clause the compiler accepts (well-typed `bool`
expression, respecting §7.2's purity/self-reference rules) is —
depending on how the program is compiled — either:

- **compiled normally** (the default): every contract clause is fully
  type-checked and validated for the rules in §7.2, but emits **no
  code at all** and has **zero runtime cost** — a normally-compiled
  program cannot observe that it has contracts; or
- **compiled with contract checking on** (an explicit, separate
  compilation mode — deliberately not specified further here, since
  *how* a program opts into this is an implementation/tooling question,
  not a language question): every `requires` is checked at each call
  site (or on entry — an implementation choice) before the function
  body runs; every `ensures` is checked at each `return`; every
  `invariant` is checked at the two points in §7.3; every `decreases`
  is checked as in §7.4. A failing check **halts the program**
  immediately with a diagnostic naming the failed clause, its source
  location, and (implementation-defined) enough context to identify
  which call/iteration failed.

This mirrors the same "opt-in, zero-cost-by-default" shape Hoare's own
`POSTULATE_STACK_CHECK` debug instrumentation already uses for a
different problem (stack corruption) — a deliberate, consistent pattern
for this project: **verification-adjacent tooling is always something
you turn on, never something baked permanently into every build.**

A future language version may add genuine static verification (proving
a clause true for *all* inputs, not just the ones a checked build
happens to run on) — that is explicitly out of scope for v1; see §11.

### 7.6 `old(...)` and `result`

Both are contextual keywords (§1.4). They don't extend to the same set
of positions, and that asymmetry is deliberate:

- `old(param)` — `param` must be a bare parameter name of the enclosing
  function. Refers to that parameter's value as it was at function
  entry, before the function body ran. Type: same as the parameter's
  own declared type. Valid inside an `ensures` clause **or** a `while`
  loop's `invariant` clause (§7.3) — its meaning never depends on which
  of the two it's written in, since it always names the *function's*
  entry snapshot, never something loop-iteration-relative. (`old` does
  not appear in `requires` — at the point a precondition is checked,
  "entry" and "now" are the same moment, so it would be redundant
  there; using `old(...)` in a `requires` clause is a compile error.)
- `result` — refers to the function's own return value. Valid **only**
  in a non-`void` function's `ensures` — not `invariant`, unlike `old`
  and `requires` (§7.6a): a `while` loop can run to completion many
  times over before the function it's in ever returns, so there is no
  return value yet to name while a loop is still running, regardless of
  what the eventual `return` will produce. Using `result` in a `void`
  function's `ensures`, inside an `invariant`, or anywhere else outside
  an `ensures` clause, is a compile error.

### 7.6a Referencing `requires` from `ensures` and `invariant`

Inside a function's `ensures` clause, **or** inside the `invariant`
clause of one of its `while` loops, the bare word `requires` — no
parentheses, no arguments, an ordinary `bool`-typed expression atom —
refers to that same function's own `requires` clause, re-checked.
Concretely, it is defined by substitution: `requires`, used this way, is
replaced by a copy of the function's `requires`-clause expression,
spliced into the enclosing expression at that point, and the whole
expression is then type-checked and (in a checked build, §7.5)
evaluated normally — exactly as if the precondition's formula had been
retyped there by hand.

The consequence worth being precise about is what "normally" means for
the free variables inside that copy: unlike an `old(param)` reference, a
bare `requires` is **not** implicitly wrapped in `old` — every parameter
it mentions resolves to its **current** value at the point it is
checked (post-execution, for `ensures`; whatever holds at that loop
checkpoint, for `invariant`), the same as any other unwrapped identifier
there. That is the intended reading: `requires` asks "does the
precondition's formula, evaluated against the state as it is *now*,
still hold?" — not "did it hold at entry" (which would just restate
what `requires` itself already guaranteed at the point it was first
checked, and be pointless to ask again). This is well-defined precisely
because a `requires` clause itself can never contain `old(...)` (§7.6 —
at entry, "current" and "old" are the same moment) — a substituted-in
copy therefore never carries a stray `old` reference whose meaning
would need re-deriving at the splice point.

```postulate
function add(x: int, y: int) : int [
  requires: x >= 0 && y >= 0;
  ensures: requires && old(x) + old(y) <= result;
] {
  return x + y;
}
```

Here `requires` inside `ensures` expands to `x >= 0 && y >= 0`, checked
against `x`/`y`'s values when `add` returns. For `add` specifically,
which never reassigns its own parameters, that ends up equivalent to
checking it against their entry values — a slightly redundant
illustration on its own. It stops being redundant the moment a function
*can* change what a parameter refers to (a `ref` parameter, §5.3a, or
writing through a pointer parameter): there, "the precondition still
holds now" is a genuinely different, informative claim from "the
precondition held at entry."

The same mechanism inside a loop's `invariant` — checking the
precondition at *every* loop checkpoint, not just once at the end. Note
that this only makes sense for a part of `requires` the loop itself
doesn't drive toward becoming false (a loop counting `n` down from
`n > 0` obviously can't also promise `n > 0` after its own last
iteration) — a `requires` clause about something the loop leaves alone
is the natural fit:

```postulate
function scale_buffer(ref buf: *int32, len: uint64, factor: int32) : void [
  requires: buf != null;
  ensures: true;
] {
  mut i : uint64 := 0;
  while (i < len) [
    invariant: requires;             // "buf != null" still holds at
                                       // every checkpoint -- true here
                                       // since the loop body never
                                       // reassigns buf itself (only
                                       // buf[i]), but would be a
                                       // genuine, checked claim the
                                       // moment some branch could
    invariant: i <= len;
    decreases: len - i;
  ] {
    buf[i] := buf[i] * factor;
    i := i + 1;
  }
}
```

`requires` used this way is a **whole expression atom**, not a value
that can be indexed into or called — `requires.foo` or `requires()` are
compile errors, the same category of mistake as calling `result` or
writing `old(x).y` where accessing `x`'s own field would otherwise be
legal (§7.6). Shadowing works exactly like `old`/`result` already do
(§1.4): the contextual meaning applies only in the positions it
occupies (bare, inside that function's own `ensures` or one of its
loops' `invariant`) — a parameter or local literally named `requires`
is simply unreachable by that name in those positions, the same
trade-off `old`/`result` already make everywhere else.

This still does **not** extend to `decreases` — a `bool`-typed reference
wouldn't type-check as a `decreases` measure regardless of which clause
it came from, so there's no version of this worth defining there.

### 7.6b `last(...)`

New: a contextual keyword (§1.4), valid inside a `while` loop's
`invariant` clause, or inside a `decreases` clause — whether that
`decreases` is attached to a `while` loop or, per §7.4, to a recursive
`pure` function. `last(expr)` names the value `expr` had at the
*previous point in the same evaluation chain* that `decreases` already
tracks for its own comparison (§7.4): the previous loop iteration's
checkpoint, or the previous recursive call — whichever applies to the
clause it's written in.

**Unlike `old` (§7.6), `last`'s argument is a general expression, not
restricted to a bare parameter name** — a deliberate asymmetry, not an
oversight. `decreases` already forces the checker to remember the value
of an arbitrary expression across the iteration/call boundary purely to
do its own automatic comparison; `last` just gives the programmer a name
for a value the checker was already computing, so allowing it on any
expression adds no implementation cost beyond what `decreases` already
demands. `old` would need to start remembering arbitrary sub-expressions
specifically to support that generality — a genuinely bigger ask, which
is why it stayed narrow (§7.6).

**At the very first checkpoint** — before a loop's first iteration, or
at the outermost call of a recursive chain — there is no previous point
to name. `last(expr)` is defined there as simply `expr`'s own current
value at that same checkpoint (`last(expr) == expr` holds by definition
at the first checkpoint) — a total, always-defined value, the same
treatment `old`/`result`/`requires` get, rather than something a program
would need to guard against as undefined.

This is a genuinely **different** rule from `decreases`'s own
comparison (§7.4), and the two are related tools, not one mechanism
wearing two names: `decreases`'s comparison doesn't evaluate-and-fail at
the first checkpoint, it skips the strict-decrease check there entirely
— a hardcoded exemption for its one fixed shape (`E >= 0`, and `E <`
*previous* `E` from the second checkpoint on). `last`, by contrast, is
just a value with a total definition; any relation built out of it —
including a strict one, like `count > last(count)` — is checked exactly
as written, first checkpoint included. If that makes a particular
invariant false at loop entry (`count > last(count)` is false there,
since the two are equal by definition), that is the same honest
feedback any other wrong invariant already gives (§7.3), not a bug in
`last` — write `count >= last(count)` if "never decreases" (rather than
"strictly increases every single checkpoint, including the first") is
what's actually meant.

```postulate
function count_up_to(limit: int32) : int32 [
  requires: limit >= 0;
  ensures: result == limit;
] {
  mut n : int32 := 0;
  while (n < limit) [
    invariant: n >= 0 && n <= limit;
    invariant: n >= last(n);           // never goes backwards -- holds
                                         // trivially (n == last(n)) at
                                         // the very first checkpoint,
                                         // strictly (n > last(n)) after
    decreases: limit - n;
  ] {
    n := n + 1;
  }
  return n;
}
```

`last(expr)` is, like `old`/`requires`, a **whole expression atom** —
not a value that can be further indexed into or called from outside the
parentheses: `last(p).field` is a compile error, not "the previous
value of `p`'s field." Write `last(p.field)` instead — putting the
projection *inside* the argument snapshots exactly the sub-value
wanted, and sidesteps ever needing to define what indexing into a
snapshot would mean. For the same reason, `last`'s own argument may not
itself contain `old`, `result`, `requires`, or another `last` — nesting
these contextual constructs inside one another is a compile error,
keeping each one's meaning self-contained rather than needing a rule for
every combination.

`last` is a compile error anywhere outside those two clause kinds — in
particular, **not** in `requires` or `ensures` directly (a function
isn't itself iterated; `old`, §7.6, is the function-entry equivalent
already available there).

### 7.7 Derivation rules (formal foundation)

§7.1–§7.6 describe *what* gets checked and *where*. This section is
*why* those particular points are the right ones — the actual,
classical proof calculus (Hoare logic, in the relational-model notation
of Fóthi's *Introduction to Programming*, the tradition this whole
verification vocabulary is drawn from — see "About this document").
These three rules aren't a v1 invention; v1's checking points were
chosen *because* of them, not the other way around.

Notation: for a predicate $Q$ over the state space $A$ and a program
fragment $S$, $lf(S, Q)$ is the **weakest precondition** — the weakest
predicate on which $S$ is guaranteed to terminate and leave the state
satisfying $Q$ (Dijkstra's $wp(S, Q)$; this textbook tradition calls it
$lf$, "legyengébb feltétel" — weakest condition). $Q \Rightarrow lf(S,
R)$ reads: "$Q$ is strong enough to guarantee $S$ establishes $R$."

**Sequence.** Let $S = (S_1; S_2)$, and $Q$, $R$, $Q'$ predicates over
$A$. If

1. $Q \Rightarrow lf(S_1, Q')$, and
2. $Q' \Rightarrow lf(S_2, R)$,

then $Q \Rightarrow lf(S, R)$.

This is why a function body (`func_block`, §4.1) can be checked one
statement at a time, threading an intermediate assertion $Q'$ from each
statement to the next, rather than reasoning about the whole body in
one step — exactly the technique the worked example's original
hand-written sketch already used, naming an intermediate predicate
after each assignment (§12).

**Selection.** Let $IF = (\pi_1 : S_1, \ldots, \pi_n : S_n)$, and $Q$,
$R$ predicates over $A$. If

1. $Q \Rightarrow \bigwedge_{i=1}^{n} (\pi_i \vee \neg \pi_i)$, and
2. $Q \Rightarrow \bigvee_{i=1}^{n} \pi_i$, and
3. $\forall i \in [1..n]: Q \wedge \pi_i \Rightarrow lf(S_i, R)$,

then $Q \Rightarrow lf(IF, R)$.

This is `if`/`elseif`/`else` (§4.3) in its general, $n$-branch form:
$\pi_1, \ldots, \pi_n$ are the successive guards (each `if`/`elseif`
condition, with a trailing bare `else` covering whatever's left, so
rule (2)'s "some guard holds" is satisfied by construction), and rule
(3) is why each branch only ever has to be checked against $R$ *under
its own guard* — not against every other branch's. v0's plain binary
`if`/`else` was always just the $n = 2$ case of this same rule;
`elseif` (§4.3) makes the general $n$-branch shape directly writable,
instead of needing nested `if`s inside `else` to express the same
thing.

**Iteration.** Let $P$, $Q$, $R$ be predicates over $A$, $t : A \to
\mathbb{Z}$ a function, and $DO = (\pi, S_0)$. If

1. $Q \Rightarrow P$, and
2. $P \wedge \neg\pi \Rightarrow R$, and
3. $P \Rightarrow \pi \vee \neg\pi$, and
4. $P \wedge \pi \Rightarrow t > 0$, and
5–6. $P \wedge \pi \wedge t = t_0 \Rightarrow lf(S_0, P \wedge t < t_0)$,

then $Q \Rightarrow lf(DO, R)$.

This is `while` (§4.4) exactly as §7.1/§7.3/§7.4 already describe it —
$P$ is the loop's `invariant`, $\pi$ is the loop condition, $t$ is the
`decreases` measure, $S_0$ is the loop body. Rule (1) is why an
`invariant` must already hold the moment the loop is reached (checked
against whatever preceded it, §7.3); rule (2) is why the code *after*
the loop can rely on `invariant && !condition` the instant the loop
ends naturally; rules (3)/(4)/(5–6) are why `decreases` must be
positive and strictly shrinking on every pass that actually runs the
body (§7.4). Together, these six clauses are the standard
partial-correctness-plus-termination package — §4.4/§7.1 already force
every `while` to state the two pieces ($P$, $t$) this rule needs;
nothing here changes that, it's the justification for why those two
pieces, specifically, were the ones made mandatory.

`old`/`requires`/`last` (§7.6/§7.6a/§7.6b) don't change this rule
either — they let $P$ (and $t$) refer to a couple of extra, well-defined
quantities beyond the live state $A$ (the function's entry snapshot,
the previous checkpoint's value of some expression), but $P$ and $t$
stay ordinary predicates/measures over an — implicitly enriched —
state once those are available; the rule above doesn't need to know
where a predicate's sub-terms came from to hold.

---

## 8. Semantic rules — summary

Collects rules enforced by name/type checking (each also stated at its
point of use above); only the v1-specific additions are new here — v0
§7's rules (name resolution, no partially-initialized composites, no
implicit conversion, composite values across calls) are all unchanged
and still apply.

### 8.1 Contract validation

- Every `requires`/`ensures`/`invariant`/`decreases` expression must be
  a well-typed `bool` (or, for `decreases`, an integer-typed)
  expression, by the same rules as any other expression.
- Only `pure`-marked functions may be called from within a contract
  clause (§7.2).
- A function's contract clauses may not call that function, directly or
  transitively (§7.2).
- `old(...)` only in `ensures` or `invariant`, argument a bare
  parameter name (§7.6).
- `result` only in a non-`void` function's `ensures` — not `invariant`
  (§7.6).
- Bare `requires` (the function's own precondition, substituted) only
  in `ensures` or `invariant` (§7.6a).
- `last(expr)` only in `invariant` or `decreases`, `expr` itself not
  containing `old`/`result`/`requires`/`last` (§7.6b).
- A `pure` function that is (directly or mutually) recursive must carry
  its own `decreases` clause (§5.3/§7.4); a non-recursive function
  (`pure` or not) carries no `decreases` requirement at all.
- Every function (`extern` excepted, §7.1) must have at least one
  `requires` and at least one `ensures` **somewhere** — on its
  definition if it has no separate forward declaration, or on its
  forward declaration if it has one (never both, §5.2). Zero clauses
  anywhere for a given function is a compile error; this is checked
  once per function, not once per `function_decl` production, since a
  forward-declared function's clauses legitimately live apart from its
  body.
- Every `while` must have at least one `invariant` and at least one
  `decreases` clause (§4.4/§7.1) — no forward-declaration exception
  applies here, since a loop has no equivalent split form.

### 8.2 Purity

- A `pure` function may not call `extern` functions, directly or
  transitively.
- A `pure` function may not write through any pointer (parameter,
  local, or reached via further indirection), directly or transitively
  — reading through a pointer is unrestricted.

### 8.3 Control flow reachability

- Every execution path through a non-`void` function must reach a
  `return` (§4.5) — now a genuine reachability property, since `return`
  (and `break`/`continue`, which also end a path early) may appear
  anywhere, not only as a block's last statement.
- Code statically unreachable because it follows a `return`, `break`,
  or `continue` within the same block is a compile error (§4.5).
- `break`/`continue` are only valid lexically inside a `while` body
  (§4.6).

### 8.4 `#include` resolution

- Paths resolve relative to the including file, not the compiled
  program's entry file or the working directory (§6.2).
- A file already included anywhere earlier in the same compilation is
  silently skipped on a repeat `#include` (§6.2).
- A genuine inclusion cycle is a compile error (§6.2).
- Every `#include` in a file must precede every non-comment,
  non-`#include` content in that same file — checked per file, not
  globally across the whole inclusion graph (§6.2).

### 8.5 Casts

- `as`'s left operand must be a valid lvalue (§3.10); its right operand
  a `type`.
- Only the conversions listed in §3.7a's table are allowed; every other
  pairing is a compile error.

---

## 9. Complete grammar (EBNF)

```ebnf
program            ::= top_level_decl+
top_level_decl      ::= function_decl | struct_decl | extern_decl | operator_decl
include_directive    ::= "#" "include" quoted_path ";"
quoted_path          ::= '"' path_text '"'

struct_decl        ::= "struct" identifier "{" field_decl+ "}"
field_decl         ::= identifier ":" type ";"

function_decl      ::= ("pure")? "function" identifier "(" params? ")" ":" return_type
                        contract_block? (func_block | ";")
contract_block     ::= "[" contract_clause+ "]"
return_type        ::= type | "void"
extern_decl        ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
operator_decl      ::= "operator" op_symbol "(" param "," param ")" ":" return_type func_block
op_symbol          ::= "==" | "!=" | "<" | ">" | "<=" | ">=" | "+" | "-" | "*" | "/" | "%"
params             ::= param ("," param)*
param              ::= ("ref")? identifier ":" type

contract_clause    ::= requires_clause | ensures_clause | decreases_clause
requires_clause    ::= "requires" ":" expr ";"
ensures_clause     ::= "ensures" ":" expr ";"
decreases_clause   ::= "decreases" ":" expr ";"
invariant_clause   ::= "invariant" ":" expr ";"

func_block         ::= "{" decl* stmt* "}"
block              ::= "{" stmt* "}"
decl               ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"

stmt               ::= assign_stmt | incdec_stmt | if_stmt | while_stmt | return_stmt
                      | break_stmt | continue_stmt | expr_stmt

assign_pair        ::= lvalue assign_op expr
assign_op          ::= ":=" | ":+" | ":-" | ":*" | ":/"
assign_stmt        ::= assign_pair ("," assign_pair)* ";"
incdec_stmt        ::= ("++" lvalue | lvalue "++" | "--" lvalue | lvalue "--") ";"
lvalue             ::= "*" lvalue | identifier ( "[" expr "]" | "." identifier )*

if_stmt            ::= "if" "(" expr ")" block
                        ("elseif" "(" expr ")" block)*
                        ("else" block)?
while_stmt         ::= "while" "(" expr ")" "[" loop_clause+ "]" block
loop_clause        ::= invariant_clause | decreases_clause
return_stmt        ::= "return" expr? ";"
break_stmt         ::= "break" ";"
continue_stmt      ::= "continue" ";"
expr_stmt          ::= expr ";"

expr               ::= logic_or
logic_or           ::= logic_and ("||" logic_and)*
logic_and          ::= comparison ("&&" comparison)*
comparison         ::= bit_or (("==" | "!=" | "<" | ">" | "<=" | ">=") bit_or)?
bit_or             ::= bit_xor ("|" bit_xor)*
bit_xor            ::= bit_and ("^" bit_and)*
bit_and            ::= shift ("&" shift)*
shift              ::= additive (("<<" | ">>") additive)*
additive           ::= multiplicative (("+" | "-") multiplicative)*
multiplicative     ::= exponent (("*" | "/" | "%") exponent)*
exponent           ::= unary (("**" | "_/") exponent)?
unary              ::= ("!" | "-" | "&") unary | cast_deref_or_postfix
cast_deref_or_postfix ::= lvalue "as" type | "*" unary | postfix
postfix            ::= primary postfix_op*
postfix_op         ::= "[" expr "]" | "." identifier | "(" args? ")"
primary            ::= struct_literal | array_literal | identifier | literal
                      | sizeof_expr | lengthof_expr | "(" expr ")"
sizeof_expr        ::= "sizeof" "(" (type | expr) ")"
lengthof_expr      ::= "lengthof" "(" (type | expr) ")"
args               ::= arg ("," arg)*
arg                ::= ("ref")? expr

struct_literal     ::= identifier "{" field_init ("," field_init)* "}"
field_init         ::= identifier ":=" expr

array_literal      ::= "{" expr_list "}"
expr_list          ::= expr ("," expr)*

literal            ::= integer_literal | float_literal | char_literal
                      | bool_literal | null_literal
integer_literal    ::= decimal_form | based_form
decimal_form       ::= digit+
based_form         ::= digit+ "n" value_digit+
float_literal      ::= digit+ "." digit+ (("e" | "E") ("+" | "-")? digit+)?
char_literal       ::= "'" (char_body | escape_seq) "'"
escape_seq         ::= "\" ("n" | "t" | "r" | "0" | "\" | "'")
bool_literal       ::= "true" | "false"
null_literal       ::= "null"

base_type          ::= "int8" | "int16" | "int" | "int32" | "int64"
                      | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "uintptr"
                      | "bool" | "char"
                      | "float32" | "float64" | "float"
                      | "ufloat32" | "ufloat64" | "ufloat"
                      | identifier
type               ::= "*" base_type "[" integer_literal "]"
                      | "*" "void"
                      | "*" type
                      | base_type "[" integer_literal "]"
                      | "(" type ")"
                      | base_type

identifier         ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
digit              ::= "0".."9"
value_digit        ::= "0".."9" | "a".."f" | "A".."F"

comment            ::= line_comment | block_comment
line_comment       ::= "//" (any_char_except_newline)* newline
block_comment      ::= "/*" (any_char)* "*/"

keywords           ::= "function" | "struct" | "extern" | "mut" | "const" | "pure"
                      | "ref" | "operator"
                      | "if" | "else" | "elseif" | "while" | "return" | "break" | "continue"
                      | "as" | "sizeof" | "lengthof"
                      | "true" | "false" | "null"
                      | "int8" | "int16" | "int" | "int32" | "int64"
                      | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "uintptr"
                      | "bool" | "void" | "char"
                      | "float32" | "float64" | "float" | "ufloat32" | "ufloat64" | "ufloat"

contextual_keywords ::= "requires" | "ensures" | "invariant" | "decreases"
                        | "old" | "result" | "last"
                        -- see §1.4: these are ordinary identifiers everywhere
                        -- except the grammar position(s) each is listed at above
                        -- ("requires" has two: a contract_block clause keyword,
                        -- and a bare expression atom inside "ensures"/"invariant",
                        -- §7.6a; "old" is valid in both of those same two
                        -- clauses too, §7.6 -- "result" alone stays ensures-only;
                        -- "last(expr)" is valid in "invariant" and "decreases", §7.6b)
```

The `type` rule's alternatives apply in order, first match wins — see
v0 §2.5 for what this means for `*T[N]` vs. `*(T[N])`; `*void` follows
the same first-match discipline, tried before the general `"*" type`
recursive case.

`cast_deref_or_postfix`'s three alternatives are tried in that order.
The first, `lvalue "as" type`, is why `*p as int32` casts the
*dereferenced value* (§3.7a) rather than the pointer: `lvalue` itself
already matches a leading `*` (`lvalue ::= "*" lvalue | ...`, §3.10), so
it greedily consumes `*p` as one lvalue before ever checking for a
trailing `as` — only if that check fails (no `as` follows) does parsing
back up and retry via the second alternative, `"*" unary` (plain
dereference, matching v0's existing `*unary` shape — this is what makes
`*f()`, dereferencing a call's result, still work, since a call is never
part of `lvalue`). The third, plain `postfix`, is the final fallback for
everything with no leading `*` and no trailing `as` at all. Working out
the exact backtracking this requires in a hand-written recursive-descent
parser (v0's `lvalue` and `primary` productions already overlap enough
to need care — see v0's own implementation notes) is left to whoever
implements Stage 1; this document specifies
the *language*, not the parsing algorithm.

`sizeof(...)`/`lengthof(...)`'s argument (§2.7a) is ambiguous the same
way in principle — `type` and `expr` overlap for a bare identifier (it
could name either a struct type or a variable). Resolved the same PEG
way as everything else here: try `type` first (which also successfully
matches every builtin type keyword an `expr` parse never could, e.g.
`sizeof(int32)`), and only fall back to `expr` if that fails.

## 10. Standard library (out of scope, noted for context)

v1 introduces just enough (pointers, pointer arithmetic, `char`,
structs, `*void`, explicit casts) to make a **library-level** string
type buildable — deliberately, per §2.9, rather than building `string`
into the compiler. This section isn't a spec for that library (no
standard library work is part of v1 itself) — it's a note that the
capability now exists, for whenever that work happens.

### 10.1 What a `string` library would need

Sketching the shape, to sanity-check that v1's primitives are actually
sufficient — not a commitment to this exact design:

```postulate
struct string {
  data : *char;
  len  : uint;
}
```

`main`'s `argv : **char` (§6.3) is exactly the input such a library
would parse (via `while (p != null-terminator) ...` byte-scanning, or a
known length if the runtime provides one) into a `string[]`-equivalent.
Nothing about this needs new language features beyond what §1–§9
already define.

### 10.2 Console I/O

Also noted for whenever standard-library work happens (not part of v1
itself): a thin, ergonomic wrapper around `sys_read`/`sys_write` (§5.2)
for console input/output — the kind of `print`/`read_line`-style
functions the very first hand-sketched sample this whole design
conversation started from (`extern function print(val : uint) : void;`)
already assumed would exist. `sys_read`/`sys_write` are already
sufficient primitives for this (raw `*uint8` buffers, a file descriptor
— `1`/`0` for stdout/stdin); nothing new is needed at the language
level, only library code layered on top.

### 10.3 Threading helpers

Also noted for whenever standard-library work happens: `sys_clone`/
`sys_futex`/`sys_gettid`/`sys_exit_group` (§5.2) are raw primitives, not
an ergonomic threading API — using them safely from Postulate code needs
a small stack of library/runtime pieces built on top, none of which
require new language features (§1–§9 are already sufficient, same claim
§10.1 makes for `string`):

- **`thread_create(fn, arg)`** — allocates a stack (`sys_mmap`),
  arranges the trampoline `sys_clone`'s child-side "return with no
  frame to return to" problem needs (§5.2's `sys_clone` note), and
  starts `fn` running on it via `sys_clone`. The trampoline itself is
  the one piece that cannot be plain Postulate source calling `extern
  function`s — it needs the same kind of hand-written low-level
  support `_start` already is in this compiler.
- **`thread_join`**, built on `sys_futex` (the child signals its own
  exit slot, the joining thread futex-waits on it) plus `sys_exit_group`
  vs. per-thread `sys_exit` chosen correctly at the child's end (§5.2).
- **`mutex`/`condvar`** — the standard `sys_futex`-based building
  blocks (an atomic-compare-and-wait primitive is enough to build both;
  `sys_futex`'s `FUTEX_WAIT`/`FUTEX_WAKE` operations are exactly this).
  Atomic compare-and-swap itself isn't in v1's operator set (§3) and
  would need its own small design pass if a lock-free version is wanted
  — a straightforward futex-only mutex doesn't need one.

None of this is designed in any depth here — like §10.1/§10.2, this is
a sketch confirming v1's primitives are sufficient to build it, not a
commitment to the exact shape.

---

## 11. Deferred beyond v1

Explicitly discussed and intentionally **not** part of v1:

1. **Namespaces / qualified names** (`ns.symbol`-style) — planned as
   the very next step after v1 (informally, "v1.1"), specifically to
   properly scope names pulled in through `#include` (§6.2), which for
   now still dumps everything into one flat global namespace exactly
   like a single-file v0 program. This is also explicitly flagged as
   laying groundwork toward an eventual object-oriented capability,
   though no further design work on that has happened yet.
2. **True separate compilation** (independently built, cached/reusable
   compiled units, not just one big textual splice, §6.2) — a bigger
   undertaking than namespaces (it touches linking, not just name
   resolution), needed for the same underlying reason (`#include`
   re-parsing everything from source on every build doesn't scale
   indefinitely), but tracked as its own, likely-later piece of work.
   §6.2's file-scoped visibility rule was chosen specifically to make
   this practical for an implementation that wants it; v1 itself still
   doesn't mandate it.
3. **Static verification** (proving a `requires`/`ensures`/`invariant`/
   `decreases` clause true for *all* inputs, e.g. via an SMT solver) —
   v1's contracts are runtime-checked only (§7.5), by deliberate choice,
   not as a stepping stone whose "real" follow-up is already planned in
   any detail. Whether/how static proving happens is entirely open.
4. **A `string` standard library type**, **console I/O helpers**, and
   **threading helpers** (`thread_create`/`thread_join`/`mutex`/
   `condvar`, §10) — all buildable on v1's primitives, none designed or
   built as part of v1 itself.
5. **Struct field reflection** (querying a struct type's field list at
   compile time, in a form usable for indexing into it) — discussed,
   genuinely wanted, but not designed here: doing this soundly without
   breaking static typing needs its own dedicated design pass, and
   overlaps enough with the polymorphism/type-class work (item 7) that
   it makes more sense to design them together than to bolt a narrow
   version on now.
6. **A general foreign-function interface** — `extern function` still
   names one fixed, Hoare-recognized set of Linux syscalls (v0 §5.2);
   v1 does not open this up to arbitrary external symbols.
7. **Polymorphic (generic) functions and type classes** — noted as a
   clear future direction, no design work done yet; §5.4's operator
   overloading and item 5's struct reflection are both deliberately
   scoped to *not* need this, so that neither has to wait for it.
8. **Further preprocessor directives** beyond `#include` (§6.2) — macro
   expansion, conditional compilation — noted as plausible, not
   designed.
9. **Any language-level data-race protection.** `sys_clone` (§5.2) makes
   genuinely concurrent, shared-address-space threads possible in v1,
   but nothing in the type system or checker knows that two threads can
   now execute at once — a pointer or `ref` parameter (§2.5/§5.3a) can
   be handed to a second thread and mutated concurrently with the
   first's use of it, with no compiler-detected data race, no borrow
   discipline, and no atomic-operation type distinct from an ordinary
   one. This also has a real, if narrow, consequence for §7: a `pure`
   function's no-external-mutation guarantee (§7.2) and a loop
   `invariant` (§7.3) are both reasoned about as if nothing outside the
   current statement's execution can change memory between one checked
   point and the next — true single-threaded, not guaranteed true if
   another thread is concurrently mutating the same memory through a
   pointer it was handed. v1 does not attempt to close this: contracts
   stay runtime-assertion-only regardless (§7.5), and concurrent
   correctness is left entirely to the programmer, same as raw C
   pthreads. Whether/how this gets addressed (an ownership/borrowing
   discipline, an explicit atomic type, something else) is entirely
   open and not part of v1.

---

## 12. Worked example

The Euclidean-algorithm sample this whole design conversation started
from, rewritten in final v1 syntax. The original's informal Fóthi-style
relational annotations (state-space/precondition/invariant/postcondition
comments) become real `requires`/`ensures`/`invariant`/`decreases`
clauses; the self-referential postcondition problem (§7.2) is resolved
by introducing `gcd_spec`, a separate `pure` function that mirrors the
textbook recursive definition of gcd and is what `lnko`'s `ensures`
actually checks against — `lnko` and `gcd_spec` are two independently
written computations of the same thing, cross-checked at runtime in a
contract-checked build (§7.5), never against each other's own claim
about themselves.

```postulate
// Postulate v1 sample: greatest common divisor, by repeated subtraction,
// specified against an independent recursive definition.

extern function print(val : uint) : void;

pure function gcd_spec(a : uint, b : uint) : uint [
    requires: true;
    ensures: true;
    decreases: b;
] {
    if (b == 0) {
        return a;
    }
    return gcd_spec(b, a % b);
}

function lnko(x : uint, y : uint) : uint [
    requires: x > 0 && y > 0;
    ensures: result == gcd_spec(old(x), old(y));
] {
    mut c : uint := x;
    mut d : uint := y;

    // c and d always hold two numbers whose gcd is the answer we're
    // after; the loop narrows them toward equality without ever
    // changing that gcd.
    while (c != d) [
        invariant: c > 0 && d > 0;
        invariant: gcd_spec(c, d) == gcd_spec(x, y);
        decreases: c + d;
    ] {
        if (c > d) {
            c := c - d;
        } else {
            d := d - c;
        }
    }

    return d;
}

function main(argv : **char, argc : uint16) : void [
    requires: true;
    ensures: true;
] {
    print(lnko(10, 4));   // gcd(10, 4) = 2
}
```

A few smaller snippets, showing the features this example doesn't
naturally exercise (each still carries the mandatory `requires`/
`ensures`/loop clauses, §7.1, even where the contract itself is
trivial):

```postulate
// char, pointer arithmetic, explicit casts
function string_length(s : *char, max_len : uint64) : uint [
    requires: s != null;
    ensures: result <= max_len;
] {
    mut p : *char := s;
    mut end : *char := s + max_len;    // a required bound -- a bare NUL
                                         // scan has no decreasing measure
                                         // to offer without one (§7.4 asks
                                         // for a real termination proof,
                                         // and "scan until you happen to
                                         // find a NUL" doesn't supply one
                                         // on its own)
    while (*p as uint8 != 0 && p < end) [
        invariant: p >= s && p <= end;
        decreases: end - p;          // pointer difference is already
                                       // int64 (§2.5), no cast needed
    ] {
        p := p + 1;
    }
    mut diff : int64 := p - s;   // as's left operand must be an lvalue
    return diff as uint;          // (§3.7a) -- bind the pointer difference first
}

// floats/ufloats, ** exponentiation
function circle_area(radius : ufloat64) : ufloat64 [
    requires: true;
    ensures: true;
] {
    const pi : ufloat64 := 3.14159265358979;
    return pi * radius ** 2.0;   // radius can never be negative --
                                   // ufloat64 (§2.4) says so in the
                                   // type itself, not just in a comment
}

// break/continue (desugared per §4.6, not a real jump), loop clauses
function count_positive(arr : int32[10]) : int32 [
    requires: true;
    ensures: result >= 0 && result <= 10;
] {
    mut count : int32 := 0;
    mut i : int32 := 0;
    while (i < 10) [
        invariant: i >= 0 && i <= 10;
        invariant: count >= 0 && count <= i;
        decreases: 10 - i;
    ] {
        if (arr[i] <= 0) {
            i := i + 1;
            continue;
        }
        if (count == 5) {
            break;             // stop early once 5 positives are found
        }
        count := count + 1;
        i := i + 1;
    }
    return count;
}

// *void, pointer casts, heap alloc/dealloc/realloc, sizeof
extern function sys_mmap(addr: uint64, length: uint64, prot: int64,
                          flags: int64, fd: int64, offset: int64) : *void;
extern function sys_munmap(addr: uint64, length: uint64) : int64;
extern function sys_mremap(old_addr: uint64, old_length: uint64,
                            new_length: uint64, flags: int64) : *void;

function alloc_int32_buffer(n : uint64) : *int32 [
    requires: n > 0;
    ensures: true;
] {
    mut raw : *void := sys_mmap(0, n * sizeof(int32), 3, 34, 0, 0);
    return raw as *int32;
}

function grow_int32_buffer(buf : *int32, old_n : uint64, new_n : uint64) : *int32 [
    requires: new_n > old_n;
    ensures: true;
] {
    mut raw : *void := sys_mremap(buf as uintptr, old_n * sizeof(int32),
                                   new_n * sizeof(int32), 0);
    return raw as *int32;
}

function free_int32_buffer(buf : *int32, n : uint64) : void [
    requires: true;
    ensures: true;
] {
    sys_munmap(buf as uintptr, n * sizeof(int32));
}

// lengthof
function sum_array(arr : int32[10]) : int32 [
    requires: true;
    ensures: true;
] {
    mut total : int32 := 0;
    mut i : int32 := 0;
    while (i < lengthof(arr)) [   // == 10, but named instead of repeated
        invariant: i >= 0 && i <= lengthof(arr);
        decreases: lengthof(arr) - i;
    ] {
        total := total + arr[i];
        i := i + 1;
    }
    return total;
}

// ref parameters
function swap(ref a : int32, ref b : int32) : void [
    requires: true;
    ensures: true;
] {
    mut tmp : int32 := a;
    a := b;
    b := tmp;
}

function main_swap_demo() : void [
    requires: true;
    ensures: true;
] {
    mut x : int32 := 1;
    mut y : int32 := 2;
    swap(ref x, ref y);   // explicit at the call site too, per §5.3a
}

// elseif
function classify(n : int32) : int32 [
    requires: true;
    ensures: result == -1 || result == 0 || result == 1;
] {
    mut sign : int32 := 0;
    if (n < 0) {
        sign := -1;
    } elseif (n == 0) {
        sign := 0;
    } else {
        sign := 1;
    }
    return sign;
}

// operator overloading -- see §5.4 for the full Point/== example this
// mirrors; not repeated here.
```

(`#include` isn't shown here since it only matters across multiple
files — see §6.2's own examples.)
