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
cost, explicit memory management) second. v1's two biggest additions —
verification contracts (§7, including the optional static path via Why3,
§7.8) and the namespace/`use`/autoload module system (§6.2) — are the
language's first real steps toward the first of those two goals and
toward a real multi-file program structure, respectively; everything
else in v1 is either a practical ergonomic gap v0 left open (pointer
arithmetic, casts, early exit) or a small, deliberately scoped extension
(`char`, floating point).

Section 11 collects everything **explicitly deferred beyond v1** —
features that were discussed and intentionally not included, most
notably compile-time struct field reflection, polymorphism/generics,
and a general foreign-function interface.

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
**one flat namespace per `namespace` declaration** (§6.2) — you cannot
declare a `struct Point` and a `function Point(...)` in the same
namespace, whether or not they sit in the same physical file (§6.2's
"one namespace may span several files"). Two *different* namespaces may
freely reuse the same name for unrelated things — `\Core\Math\Point`
and `\Graphics\Point` coexist without conflict, distinguished by their
fully-qualified names, and a file that needs both simply `use`s each
under a distinct local name (§6.2a's `as`). Local names (parameters and
`decl`s) share one **per-function** namespace with each other, but are
entirely separate from this namespace.

**There is no global namespace.** Every declaration lives in exactly
one, explicitly named `namespace` (§6.2) — unlike v0's single-file
model, where "the namespace" was simply whatever one file contained.

### 1.4 Keywords

**Reserved** — cannot be used as identifiers under any circumstances:

```
function struct extern mut const pure ref operator
namespace use verified unverified
if else elseif while return break continue
as sizeof lengthof
true false null
int8 int16 int int32 int64 uint8 uint16 uint uint32 uint64 uintptr
bool void char float32 float64 float ufloat32 ufloat64 ufloat
```

(Additions over v0: `pure`, `ref`, `operator`, `namespace`, `use`,
`verified`, `unverified`, `elseif`, `break`, `continue`, `as`, `sizeof`,
`lengthof`, `uintptr`, `char`, `float32`, `float64`, `float`,
`ufloat32`, `ufloat64`, `ufloat`. `@autoload` (§6.2b) is not itself a
reserved word — `@` isn't a valid identifier-start character (§1.3) at
all, so the token `@autoload` can never be confused with an identifier
in the first place; `autoload` alone remains a completely ordinary,
freely usable name.)

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

**String literals** — new in v1, and deliberately narrow: the *only*
place one may appear is a `pattern_string`/`path_string` operand of
`@autoload` (§6.2b) — there is still no general string type (§2.9), and
this is not one either, just a lexical form those two operands need.
**Two forms are named, only one of which is actually used by anything
in v1**:

```ebnf
pure_string_literal ::= '"' raw_char* '"'
string_literal       ::= '"' (char_body | escape_seq)* '"'
raw_char             ::= any byte except '"' and a raw newline
```

`pattern_string`/`path_string` (§6.2b/§9) are `pure_string_literal`s —
**no escape processing of any kind**. A filesystem path or an
`@autoload` pattern has no legitimate use for a tab, a newline, or any
other character an escape sequence exists to spell — so there is
nothing to gain, and real everyday friction to cause, by making `\`
special there. A literal `\` (needed for every namespace-path separator
a pattern/path string contains) is written exactly as typed, singly —
`"\Vendor\Math\"`, not `"\\Vendor\\Math\\"` — because `raw_char` simply
copies every byte through unchanged; there is no escape mechanism to
collide with.

`string_literal` — the one *with* `char_literal`'s own escape support
(`char_body | escape_seq`, §1.5, repeated instead of taken exactly
once) — is defined here **only so the name and shape exist**, ready for
whenever a real, general string type is designed (§2.9, §11); nothing
in v1 actually accepts one anywhere yet. It is a genuinely separate
production from `pure_string_literal`, not a special case of it — a
raw, unescaped `\` (legal in `pure_string_literal`, via `raw_char`) is
*not* legal `string_literal` content on its own, only as the start of
one of `escape_seq`'s exact six forms — so the two are named next to
each other for contrast and shared vocabulary, not because one
subsumes the other. Which of the two governs a given quoted span is
entirely a property of the **grammar position** it appears in, checked
by whatever eventually parses that position — never something the
lexer itself decides token-by-token, since recognizing "a quoted span"
at all doesn't require knowing yet which of the two rules will end up
applying to it.

**Boolean literals**: `true`, `false`. **The null literal**: `null` —
unchanged from v0.

**There is still no string type** in v1 — see §2.9 for why, and what
takes its place.

### 1.6 Operators and punctuation

```
:=  ==  !=  <  >  <=  >=  &&  ||  !  &  |  ^  <<  >>  + - * /  %  **  _/  as
++  --  :+  :-  :*  :/
(  )  {  }  [  ]  :  ;  ,  .  \  @
```

New over v0: `**` (exponentiation, §3.2), `_/` (root, §3.2 — an ASCII
digraph; an earlier draft tried `√` and was reverted, see §3.2), `as`
(explicit cast, §3.7a), `++`/`--` (increment/decrement, §4.2a —
statement-only, never usable as part of a larger expression), `:+`/
`:-`/`:*`/`:/` (compound assignment, §4.2 — `:*` in particular looks
like it collides with a pointer type's leading `*`, resolved by
context-sensitive lexing, see §4.2's own note), `\` (the namespace/`use`
path separator, §6.2/§6.2a — distinct from the escape-sequence backslash
inside a `char` literal, §1.5, which never appears outside quotes), `@`
(only meaningful as the start of an `@autoload` directive, §6.2b — not a
general-purpose token). An earlier v1 draft reserved `#` for a
now-abandoned `#include` preprocessor directive; nothing in v1 uses `#`
at all.

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

Mostly unchanged from v0 (§2.4–§2.5 there): `T[N]` fixed-size, `N` a
literal, the `*T[N]` vs. `*(T[N])` first-match rule unchanged. Bounds
checking: see §2.7b (this changes from v0's plain "no runtime check" —
the compile-time literal-index check v0 already does is unaffected
either way).

**New in v1: chained `T[N][M]...` nested-array declarations.**
v0's own `type` grammar applies at most one `"[" integer_literal "]"`
suffix to a `base_type` — `int32[3][4]` is a plain syntax error there
(confirmed directly against `Hoare/src/type_parser.asm`; an earlier
draft of the v0 reference incorrectly claimed this already worked, now
corrected). v1 adds real support for chaining any number of size
suffixes (§9's own grammar: `base_type ("[" integer_literal "]")+`),
read the familiar way — leftmost is outermost:

```postulate
mut grid : int32[3][4];   // 3 elements, each an int32[4] -- grid[i][j]
```

Indexing composes the ordinary way (`arr[i][j]`, §2.4's own indexing
rule applied twice) — nothing new there, only the *declaration* syntax
is new. v0 programs never needed this: the workaround they already had
(an explicit one-field wrapper struct around the inner array, then an
array of that struct — §2.4's own note on the topic) still works
identically in v1 and compiles to the exact same flat layout; the new
syntax is purely a convenience for the common case, not a new
capability at the machine level.

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

**Changed from v0**: every function-shaped declaration now carries a
**mandatory** contract block (§7.1), and always has a body — there is
no bodyless, forward-declared form:

```ebnf
function_decl   ::= ("pure")? "function" identifier "(" params? ")" ":" return_type
                     contract_block func_block
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

**There is no forward-declared form, and no split between a signature
and its definition — a function is written once, in one file, with its
body and its one contract block together.** An earlier v1 draft allowed
a bodyless `function_decl` (terminated by `;`, contract block optional
at the grammar level) specifically so a signature could live in one
`#include`d file and its definition in another; that entire mechanism
was removed along with `#include` itself (§6.2) — the namespace/`use`
system's whole point is that a symbol has exactly one home, resolved by
its fully-qualified name (§6.2b), so there is no longer a second file
for a split declaration to usefully live in, and no ordering problem
for it to solve (recursion and forward reference within one file
already work without one, below). `contract_block` is therefore
**mandatory**, not `?`, at the grammar level too — matching §7.1's
semantic requirement ("at least one `requires`, at least one `ensures`")
directly, with no second location to check.

```postulate
function add(a: int32, b: int32) : int32 [
  requires: true;
  ensures: result == a + b;
] {
  return a + b;
}

pure function square(x: int32) : int32 [
  requires: true;
  ensures: result >= 0;
] {
  return x * x;
}
```

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

`sys_openat`/`sys_close` are also new — added to unblock the
namespace/autoload system (§6.2b): none of the syscalls above can open
a file by path, only read one already-open descriptor (`sys_read`),
which is fine for a single, stdin-fed compiler but not for one that has
to open whatever file the autoloader resolves a `use`d name to, and
every other file transitively reachable that way. `path` is written
`*char` here to match the type this table will eventually use
everywhere once `char` exists. `openat`, not the older `open`, is
deliberate: `dirfd` is always passed as `AT_FDCWD` (`-100`) since path
resolution itself is done by the caller's own string logic (the
default-mapping/pattern-matching rules §6.2b already specifies), never
left to the kernel.

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
functions defined in the same namespace work without any
declaration-order requirement, exactly as in v0 — one more reason the
forward-declared form above had nothing left to justify it once
`#include` was removed.

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
program        ::= namespace_decl autoload_decl* use_decl* top_level_decl+
top_level_decl ::= function_decl | struct_decl | extern_decl | operator_decl
```

Every file opens with exactly one `namespace_decl` (§6.2), optionally
followed by `@autoload` directives (§6.2b — legal, in practice, only in
the one file that holds `main`), then `use` declarations (§6.2a), and
only then the file's own structs/functions/externs/operators — a real
grammar production now, not a preprocessing convention layered on top
of it the way an earlier draft's `#include` was. `function_decl` no
longer has a bodyless form (§5.2) — every function-shaped declaration
has exactly one place it's written, in exactly one file, and it always
has a body.

### 6.2 Namespaces

**This replaces the earlier, discarded `#include`-based design**
entirely — textual splicing, per-file `#include` lists, and the whole
propagation-rule apparatus that grew out of trying to keep that model
both explicit and scalable at once. Postulate v1 instead adopts a real
namespace/module system, closer to how PHP (via Composer/PSR-4) or C#
organize multi-file programs than to C's headers: every file declares
which namespace it belongs to, every use of another namespace's symbol
is named explicitly, and the compiler locates the file that must define
a given symbol algorithmically, from its fully-qualified name, rather
than by following a chain of textual includes.

```ebnf
namespace_decl ::= "namespace" fqn ";"
fqn            ::= "\" identifier ("\" identifier)*
```

```postulate
namespace \Core\Math;
```

**Mandatory, and first** — a `.ptl` file with no `namespace_decl`, or
with anything other than a comment preceding it, is a compile error
("missing namespace"). There is **no** global/default namespace to fall
back to (unlike v0's or an earlier v1 draft's single-file model) — every
declaration in every file lives inside some namespace, always. `\`
(backslash) is the segment separator, chosen to look and read like a
filesystem path, since that's exactly what a namespace mostly *is* here
(§6.2b) — not a stylistic accident.

**One namespace may span several files** — `\Core\Math` isn't required
to be exactly one file; several files may each declare `namespace
\Core\Math;` and jointly contribute to it (structs, functions, and
`extern function`s declared across any of them share that one
namespace's own flat sub-namespace, §1.3). In the common case, though,
each file provides exactly **one** externally-`use`-able declaration,
**named after the file itself** — `\Core\Math\Matrix` is expected to
live in a file named `Matrix.ptl`, sitting wherever `\Core\Math` maps to
on disk (§6.2b's default rule folds the namespace's own segments
directly into a directory path, and the final, symbol-naming segment of
a fully-qualified name into the file's own basename). A file is free to
also declare smaller, private helper functions/structs alongside its
one primary, filename-matching declaration — nothing stops it — but the
*default* autoload rule (§6.2b) only ever looks for a file whose name
matches the symbol being resolved, so a second, differently-named
top-level declaration in that same file is only reliably reachable by
anyone who already knows to open that specific file directly (i.e., by
`use`ing the primary, filename-matching symbol and expecting the rest
to ride along) — not a distinct, independently-autoloadable entry point
of its own. A project that genuinely wants several equally-important,
independently-`use`d symbols should give each its own file, matching
the naming discipline throughout.

**The `\Main` namespace and the program's entry point.** The file
containing `main` (§6.3) must declare `namespace \Main;` — no other
namespace may contain a `main` function, and `\Main` may contain at
most one, project-wide (mirroring, at the namespace level, the same
uniqueness v0 already required of `main` itself). This is also where
`@autoload` overrides are legal at all (§6.2b) — tying "the one place
allowed to redirect where the loader looks for things" to "the one,
unique file that already has to exist and be unique in every project"
removes any need for a *second*, separately-enforced uniqueness rule
for where autoload configuration is allowed to live.

### 6.2a Explicit imports (`use`)

**Postulate's core transparency rule: no hidden dependencies, ever.** A
fully-qualified name (`\Core\Math\Matrix`) may **never** appear directly
in a function body or a struct's field list — only in a `use`
declaration, in the file's own header, before any real declaration.
Every external struct, function, or `extern function` a file's body
refers to must be named, once, in that header — reading a file's `use`
list is reading a *complete* account of everything it depends on,
exactly the property the discarded `#include` design spent this whole
session's earlier drafts trying, and repeatedly failing, to fully
guarantee (propagation, forward declarations, and the "who owns what"
bookkeeping that grew up around them are **all gone** — there is
nothing left to propagate, because every dependency is named, flatly,
by the file that actually has it).

```ebnf
use_decl   ::= "use" (fqn_group | fqn_single) ";"
fqn_single ::= fqn ("as" identifier)?
fqn_group  ::= fqn "\" "{" use_spec ("," use_spec)* "}"
use_spec   ::= identifier ("as" identifier)?
```

Three forms, all resolving through the same autoloader (§6.2b):

- **Single import, with an optional rename**:

  ```postulate
  use \Core\Math\Matrix;
  use \Core\Math\Matrix as MTX;
  ```

  Brings exactly one symbol into scope, under its own name or the given
  alias. `as` here is a different context from the `as` cast operator
  (§3.7a) — the two never collide, since `use ... as ...` can only ever
  appear in a file's header, never inside an expression, so the parser
  never has to disambiguate them from the same position.

- **Group import**, for several symbols from the same namespace without
  repeating its prefix:

  ```postulate
  use \Core\Math\{Matrix as MTX, Vector, calculate_norm};
  ```

- **Namespace-level import**, bringing in the *namespace itself* rather
  than one specific symbol, referenced afterward with a one-segment
  qualifier:

  ```postulate
  use \Core\Math;

  function run() : void [ requires: true; ensures: true; ] {
    mut m : Math\Matrix := Math\create_identity();
  }
  ```

  `Math\Matrix` here is **not** a fully-qualified name (that would still
  be illegal in the body, per the rule above) — it's an ordinary
  identifier reference, `Math` acting as the local alias `use \Core\Math;`
  bound to the namespace, with `\` continuing to separate the alias from
  the member being reached through it. This form trades a little of the
  single-import form's "every individual name is listed up front"
  transparency for brevity when a file genuinely uses many members of
  one namespace — still fully explicit about *which namespace*, just not
  about *which of its members*, one by one.

### 6.2b The autoloader (`@autoload`)

```ebnf
autoload_decl ::= "@autoload" "(" pattern_string "," path_string ("," verify_flag)? ")" ";"
verify_flag   ::= "verified" | "unverified"
```

```postulate
namespace \Main;

@autoload("\Vendor\Math\", "libs/math/src");
@autoload("\Plugin\:module\", "plugins/:module/src");

function main() : int32 [ requires: true; ensures: result == 0; ] {
  return 0;
}
```

`pattern_string` and `path_string` are both `pure_string_literal`s
(§1.5) — **no escapes**, every `\` above is a literal namespace-path
separator, written exactly once, never doubled. Their content is
additionally restricted to `path_char` (letters, digits, `_`, `/`, `-`,
`.`) interspersed with `:identifier` placeholder segments (§9's own
grammar) — a byte outside that set is a compile error here.

**The default rule, with no `@autoload` involved at all**: a
fully-qualified name's every segment except the last becomes a
directory path (`\Core\Math\Matrix` → `Core/Math/`), and the last
segment becomes a filename with `.ptl` appended (`Matrix.ptl`) — a
straightforward, mechanical 1:1 mapping, resolvable without reading a
single line of anyone's source first.

**`@autoload` directives override that default for a matching namespace
*prefix***, redirecting where its files are actually found on disk —
useful for vendored/third-party code, or any layout that doesn't match
the default convention. Two constraints, both load-bearing:

- **Legal only in the file that declares `main`** (`\Main`, §6.2). Since
  that file is already unique, project-wide, tying autoload
  configuration to it guarantees autoload rules can never be a *hidden*
  side effect of including some arbitrary library file — a dependency
  cannot quietly repoint where a third namespace's files come from
  (library poisoning) merely by being `use`d; only the one, obvious,
  always-present entry point can.
- **First-match wins, checked top-to-bottom.** The compiler tries each
  `@autoload` directive against a name being resolved, in the order
  written; the first whose pattern matches decides where to look. A
  name matching no directive at all falls back to the default 1:1 rule
  above — a directive list is a stack of *exceptions* to that default,
  not a replacement for it.

**Pattern matching**: a literal prefix (`"\Vendor\Math\"`) matches
only that exact namespace prefix; a named placeholder (`:module`, as in
`"\Plugin\:module\"`) matches any single namespace segment in that
position and substitutes the matched text into the corresponding
position of the path string on the other side — `\Plugin\Foo\Bar`
resolves against `"plugins/:module/src"` by binding `:module` to `Foo`,
giving `plugins/Foo/src` as the base directory `Bar` (and, if there were
more segments, the rest of the namespace path) resolves within, by the
same default folding rule the unmatched case already uses.

**The `verified`/`unverified` flag** (default `unverified` if omitted)
doesn't affect ordinary compilation at all — it's read only by the
modular verification pipeline (§6.2c), marking a namespace prefix's
files as pre-trusted (a vetted standard library, a reviewed third-party
package) so their own bodies are never re-verified, only their public
contracts loaded as axioms.

```postulate
namespace \Main;

@autoload("\Std\", "stdlib/src", verified);
@autoload("\Vendor\Math\", "vendor/math/src", unverified);

function main() : int32 [ requires: true; ensures: result == 0; ] {
  return 0;
}
```

### 6.2c Modular compilation and verification

The namespace/`use`/autoload system above isn't only a naming
convenience — it's specifically shaped so that compiling (and, once
§7.8's Why3 path is in play, *verifying*) one file never requires
reading another file's body, only its public interface:

1. **The dependency graph is determined statically, cheaply, up front.**
   A file's own `use` declarations name exactly which other
   namespaces/symbols it needs; combined with the entry point's
   `@autoload` overrides, the compiler resolves every `use` to a
   concrete file path and builds the whole project's dependency graph
   before compiling or verifying a single function body.
2. **Compiling (or verifying) a module loads only what it `use`s —
   signatures and contracts, never bodies.** A `use \Core\Math\Matrix;`
   pulls in exactly enough of `Matrix.ptl` to type-check calls into it
   (§9's grammar) and, for verification specifically, its `requires`/
   `ensures` clauses as axioms (§7.8) — `Matrix.ptl`'s own function
   bodies are not re-parsed, re-checked, or re-verified merely because
   something else `use`s them.
3. **Editing a module's implementation, without changing its public
   surface, never requires recompiling or reverifying anyone who `use`s
   it.** Only a change to what a module actually exposes (a signature,
   a contract clause) invalidates its dependents; a body-only edit is
   local to the one file that changed.
4. **Incremental caching follows directly from point 3**: the compiler
   tracks each module's own source hash (or timestamp); a module whose
   hash is unchanged since its last successful compile/verify, and whose
   own `use`d dependencies are themselves unchanged, is skipped entirely
   — its previously-recorded public interface (and, for verification,
   its already-discharged proof obligations) is reused as-is. A module
   under a `verified` autoload prefix (§6.2b) skips re-verification
   unconditionally, cache or not — it is taken as trusted, permanently,
   by that flag alone.

None of this requires reading any file's body except the one currently
being compiled/verified and the one holding `main` — a direct
consequence of `use` naming dependencies explicitly, by fully-qualified
name, resolved to exactly one file each, rather than the earlier
`#include` design's textual splicing ever having needed a body's worth
of someone else's source just to make its *signature* available.

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

**New in v1, tied to the namespace system (§6.2)**: `main` may only be
declared inside the `\Main` namespace, and at most once project-wide —
a second `function main(...)`, anywhere, `\Main` or not, is a compile
error, the namespace-level generalization of v0's own "exactly one
`main`" rule. This is also the *only* file allowed to carry `@autoload`
directives (§6.2b).

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
its founding goal of mathematically precise correctness proofs. Its
**default build pipeline** is deliberately scoped **narrowly**:
contracts are checked for well-formedness by the compiler always, but
only ever *enforced* at runtime — made to actually catch a violation —
by a separately compiled, opt-in variant of the program (§7.5). A real
static prover, built on Why3 and an SMT solver, does exist — as a
distinct, separately-invoked tool (§7.8), never a hidden part of the
default build. §7.1–§7.6 specify what a program
writes and what gets checked when; §7.7 gives the formal derivation
rules that are the actual reason those specific checking points are the
correct ones, for anyone who wants the underlying proof theory, not
just the practical rule set; §7.8 covers the optional static path.

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
function/loop with none behaved exactly as in v0). Every function must
carry **at least one** `requires` and **at least one** `ensures`; every
`while` (§4.4) must carry **at least one** `invariant` and **at least
one** `decreases`. A function/loop with no meaningful constraint still
states that explicitly — `requires: true; ensures: true;` is the honest
way to say "nothing is assumed, nothing beyond termination is
promised," not an omission.

Both are enforced **directly at the grammar level**, now that a
function's `contract_block` is mandatory rather than `?` (§5.2 — the
forward-declared/defined split an earlier draft needed this optionality
for no longer exists): `contract_block ::= "[" contract_clause+ "]"` and
`loop_block ::= "[" loop_clause+ "]"` both use `+`, not `*`, so a
function or a `while` with an empty or absent clause block is a syntax
error, full stop, the same way for both. `contract_clause+`/
`loop_clause+` only guarantees *some* clause is present, not *which*
kind — "at least one `requires` **and** at least one `ensures`" (not
just one clause of either kind) is therefore still a **semantic** rule
(§8.1), checked once per function against its one, always-present
block.

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

### 7.5 Checking model: runtime assertions by default

The **default build pipeline** (`postulate build`/whatever the ordinary
compile entry point ends up named) does **not** attempt to statically
prove any contract clause true — that is a separate, opt-in path,
§7.8. Every clause the compiler accepts (well-typed `bool` expression,
respecting §7.2's purity/self-reference rules) is — depending on how
the program is compiled — either:

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

Genuine static verification (proving a clause true for *all* inputs,
not just the ones a checked build happens to run on) **is** available
in v1, via a distinct, separately-invoked tool built on Why3 — §7.8.
Running it never changes what the default build produces; the two
paths are independent, and a program that's never run through the
static path still compiles and runs exactly as this section describes.

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

### 7.8 Static verification via Why3 (optional)

§7.5 is deliberately silent on *proving* a contract clause; this section
is where that happens, entirely outside the default build. Rather than
building a bespoke SMT front-end, v1 targets **Why3** — an existing,
mature verification platform — by translating a Postulate module and
its contracts into **WhyML**, Why3's own input language, and letting
Why3's own machinery (its VC generator, plus whichever backend solver
is configured — Z3, CVC4, Alt-Ergo, or an interactive prover such as
Coq) do the actual proof search:

```
┌────────────────────────┐
│  Postulate kód (.ptl)  │  (requires / ensures / invariant / decreases)
└───────────┬────────────┘
            │  AST transzformáció
            ▼
┌────────────────────────┐
│   WhyML kód (.mlw)     │  (Verification Conditions -- VC)
└───────────┬────────────┘
            │  Why3 Engine
            ▼
┌────────────────────────┐
│  SMT Solvers / Coq     │  (Z3, CVC4, Alt-Ergo, Coq)
└────────────────────────┘
```

**Why3, not a hand-written VC generator, for the same reason `opt`/`llc`
were chosen over a hand-rolled optimizer/backend elsewhere in this
project's own tooling** (`docs/postulate_stage1_bootstrap_plan.md`
§2): weakest-precondition calculation and SMT-solver orchestration are
exactly the kind of mature, general-purpose machinery not worth
re-implementing, and §7.7's derivation rules are already stated in
terms — sequence, selection, iteration, each with its own $lf$
obligation — that map directly onto Why3's own `while`/`if`/sequencing
VC generation, requiring no reinterpretation of the proof theory itself,
only a syntactic transformation.

**Type mapping**, the load-bearing part of the translation:

| Postulate type | WhyML | Note |
|---|---|---|
| `int32`, `int64`, … | `int` / `mach.int.Int32` | bounded or mathematical integer, per context |
| `bool` | `bool` | |
| `struct` | `record`, mutable fields | matches v1's own by-value, mutable-field semantics |
| `pure function` (§5.3) | `function`/`predicate` | side-effect-free, directly usable inside a clause, mirroring §7.2's own restriction |
| ordinary `function` | `let`/`val` | imperative code with state/effects |

**Worked example** — `increment`, a `ref`-parameter function (§5.3a)
with a contract:

```postulate
struct Counter {
    value : int32;
    step  : int32;
}

function increment(ref c : Counter) : void [
    requires: c.step > 0;
    ensures:  c.value == old(c.value) + old(c.step);
] {
    c.value :+ c.step;
}
```

```
module Szamlalo
  use int.Int
  use ref.Ref

  type counter = {
    mutable value : int;
    mutable step  : int;
  }

  let increment (c : counter) : unit
    requires { c.step > 0 }
    ensures  { c.value = (old c.value) + (old c.step) }
  =
    c.value <- c.value + c.step
end
```

`old(c.value)`/`old(c.step)` (§7.6) map directly onto WhyML's own `old`
— no reinterpretation needed, since both mean exactly the same thing:
the parameter's value at function entry.

**Invoking it** is a separate command from the default build, never a
flag on it:

```Bash
postulate verify szamlalo.ptl --solver=z3
# underlying: why3 prove -P z3 szamlalo.mlw

postulate verify szamlalo.ptl --ide
# underlying: why3 ide szamlalo.mlw   -- for obligations no automatic
#                                        solver discharges on its own
```

**Modular, incremental, and namespace-aware** — this is where §6.2c's
module system and this section meet: verifying a module loads only the
`requires`/`ensures` of whatever it `use`s, as already-proven axioms,
never re-deriving or re-checking another module's own body; a module
under a `verified` `@autoload` prefix (§6.2b) is trusted outright and
never sent through Why3 at all; everything else is verified once, and
re-verified only when its own source (or something it `use`s) actually
changes, per §6.2c's cache. A failed proof obligation is a `postulate
verify` diagnostic, not a build failure — the default build (§7.5)
neither runs nor depends on any of this.

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
  `requires` and at least one `ensures` in its one, mandatory contract
  block (§5.2/§7.1). Zero clauses of either kind is a compile error.
- Every `while` must have at least one `invariant` and at least one
  `decreases` clause (§4.4/§7.1).

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

### 8.4 Namespace/`use`/autoload resolution

- Every `.ptl` file must open with a `namespace_decl`, preceded by
  nothing but comments — a compile error ("missing namespace")
  otherwise (§6.2).
- A fully-qualified name may not appear directly in a function body or
  a struct's field list — only in a `use` declaration or (§6.2a's
  namespace-level form) as a `LocalAlias\member` reference (§6.2a).
- `@autoload` directives are legal only in the file declaring `main`
  (§6.2/§6.2b).
- Resolving a fully-qualified name tries each `@autoload` pattern in
  the order written, first match wins; no match falls back to the
  default 1:1 namespace-segments-to-directory, final-segment-to-filename
  mapping (§6.2b).
- `main` may be declared only in the `\Main` namespace, and at most once
  project-wide (§6.2/§6.3).

### 8.5 Casts

- `as`'s left operand must be a valid lvalue (§3.10); its right operand
  a `type`.
- Only the conversions listed in §3.7a's table are allowed; every other
  pairing is a compile error.

---

## 9. Complete grammar (EBNF)

```ebnf
program               ::= namespace_decl autoload_decl* use_decl* top_level_decl+

/* --- Névterek, Autoload és Importok --- */
namespace_decl        ::= "namespace" fqn ";"
use_decl              ::= "use" ( fqn_group | fqn_single ) ";"
fqn_single            ::= fqn ("as" identifier)?
fqn_group             ::= fqn "\" "{" use_spec ("," use_spec)* "}"
use_spec              ::= identifier ("as" identifier)?

autoload_decl         ::= "@autoload" "(" pattern_string "," path_string ("," verify_flag)? ")" ";"
pattern_string        ::= pure_string_literal   /* content restricted to path_char | ":" identifier, §6.2b */
path_string           ::= pure_string_literal   /* same restriction */
verify_flag           ::= "verified" | "unverified"

fqn                   ::= "\" identifier ("\" identifier)*
path_char             ::= "a".."z" | "A".."Z" | "0".."9" | "_" | "/" | "-" | "." | "\"

/* --- Deklarációk --- */
top_level_decl        ::= function_decl | struct_decl | extern_decl | operator_decl

struct_decl          ::= "struct" identifier "{" field_decl+ "}"
field_decl           ::= identifier ":" type ";"

function_decl        ::= ("pure")? "function" identifier "(" params? ")" ":" return_type
                          contract_block func_block
contract_block       ::= "[" contract_clause+ "]"
return_type          ::= type | "void"
extern_decl          ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
operator_decl        ::= "operator" op_symbol "(" param "," param ")" ":" return_type func_block
op_symbol            ::= "==" | "!=" | "<" | ">" | "<=" | ">=" | "+" | "-" | "*" | "/" | "%"
params               ::= param ("," param)*
param                ::= ("ref")? identifier ":" type

contract_clause      ::= requires_clause | ensures_clause | decreases_clause
requires_clause      ::= "requires" ":" expr ";"
ensures_clause       ::= "ensures" ":" expr ";"
decreases_clause     ::= "decreases" ":" expr ";"
invariant_clause     ::= "invariant" ":" expr ";"

/* --- Utasítások és Blokkok --- */
func_block           ::= "{" decl* stmt* "}"
block                ::= "{" stmt* "}"
decl                 ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"

stmt                 ::= assign_stmt | incdec_stmt | if_stmt | while_stmt | return_stmt
                        | break_stmt | continue_stmt | expr_stmt

assign_pair          ::= lvalue assign_op expr
assign_op            ::= ":=" | ":+" | ":-" | ":*" | ":/"
assign_stmt          ::= assign_pair ("," assign_pair)* ";"
incdec_stmt          ::= ("++" lvalue | lvalue "++" | "--" lvalue | lvalue "--") ";"
lvalue               ::= "*" lvalue | identifier ( "[" expr "]" | "." identifier )*

if_stmt              ::= "if" "(" expr ")" block
                          ("elseif" "(" expr ")" block)*
                          ("else" block)?
while_stmt           ::= "while" "(" expr ")" "[" loop_clause+ "]" block
loop_clause          ::= invariant_clause | decreases_clause
return_stmt          ::= "return" expr? ";"
break_stmt           ::= "break" ";"
continue_stmt        ::= "continue" ";"
expr_stmt            ::= expr ";"

/* --- Kifejezések --- */
expr                 ::= logic_or
logic_or             ::= logic_and ("||" logic_and)*
logic_and            ::= comparison ("&&" comparison)*
comparison           ::= bit_or (("==" | "!=" | "<" | ">" | "<=" | ">=") bit_or)?
bit_or               ::= bit_xor ("|" bit_xor)*
bit_xor              ::= bit_and ("^" bit_and)*
bit_and              ::= shift ("&" shift)*
shift                ::= additive (("<<" | ">>") additive)*
additive             ::= multiplicative (("+" | "-") multiplicative)*
multiplicative       ::= exponent (("*" | "/" | "%") exponent)*
exponent             ::= unary (("**" | "_/") exponent)?
unary                ::= ("!" | "-" | "&") unary | cast_deref_or_postfix
cast_deref_or_postfix ::= lvalue "as" type | "*" unary | postfix
postfix              ::= primary postfix_op*
postfix_op           ::= "[" expr "]" | "." identifier | "(" args? ")"
primary              ::= struct_literal | array_literal | identifier | literal
                        | sizeof_expr | lengthof_expr | "(" expr ")"
sizeof_expr          ::= "sizeof" "(" (type | expr) ")"
lengthof_expr        ::= "lengthof" "(" (type | expr) ")"
args                 ::= arg ("," arg)*
arg                  ::= ("ref")? expr

struct_literal       ::= identifier "{" field_init ("," field_init)* "}"
field_init           ::= identifier ":=" expr

array_literal        ::= "{" expr_list "}"
expr_list            ::= expr ("," expr)*

/* --- Literálok és Típusok --- */
literal              ::= integer_literal | float_literal | char_literal
                        | bool_literal | null_literal
integer_literal      ::= decimal_form | based_form
decimal_form         ::= digit+
based_form           ::= digit+ "n" value_digit+
float_literal        ::= digit+ "." digit+ (("e" | "E") ("+" | "-")? digit+)?
char_literal         ::= "'" (char_body | escape_seq) "'"
pure_string_literal  ::= '"' raw_char* '"'
string_literal       ::= '"' (char_body | escape_seq)* '"'
raw_char             ::= any byte except '"' and a raw newline
escape_seq           ::= "\\" ("n" | "t" | "r" | "0" | "\\" | "'")
bool_literal         ::= "true" | "false"
null_literal         ::= "null"

base_type            ::= "int8" | "int16" | "int" | "int32" | "int64"
                        | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "uintptr"
                        | "bool" | "char"
                        | "float32" | "float64" | "float"
                        | "ufloat32" | "ufloat64" | "ufloat"
                        | identifier
type                 ::= "*" base_type "[" integer_literal "]"
                        | "*" "void"
                        | "*" type
                        | base_type ("[" integer_literal "]")+
                        | "(" type ")"
                        | base_type

identifier           ::= ("a".."z" | "A".."Z") ("a".."z" | "A".."Z" | "0".."9" | "_")*
digit                ::= "0".."9"
value_digit          ::= "0".."9" | "a".."f" | "A".."F"

comment              ::= line_comment | block_comment
line_comment         ::= "//" (any_char_except_newline)* newline
block_comment        ::= "/*" (any_char)* "*/"

/* --- Lexikális elemek és Kulcsszavak --- */
keywords             ::= "namespace" | "use" | "@autoload"
                        | "verified" | "unverified"
                        | "function" | "struct" | "extern" | "mut" | "const" | "pure"
                        | "ref" | "operator"
                        | "if" | "else" | "elseif" | "while" | "return" | "break" | "continue"
                        | "as" | "sizeof" | "lengthof"
                        | "true" | "false" | "null"
                        | "int8" | "int16" | "int" | "int32" | "int64"
                        | "uint8" | "uint16" | "uint" | "uint32" | "uint64" | "uintptr"
                        | "bool" | "void" | "char"
                        | "float32" | "float64" | "float" | "ufloat32" | "ufloat64" | "ufloat"

contextual_keywords  ::= "requires" | "ensures" | "invariant" | "decreases"
                        | "old" | "result" | "last"
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

1. **Static verification's completeness is not guaranteed
   project-wide.** §7.8's Why3 path can prove any individual module's
   contracts, but a `verified` `@autoload` prefix (§6.2b) lets a module
   be trusted *without* ever actually being run through it — meaning
   "this project passed `postulate verify`" does not, by itself, mean
   *every* reachable module was proven, only that every module which
   wasn't already flagged trusted was. Whether/how to also guarantee
   (or at least surface) *whole-project* proof coverage — as opposed to
   per-module, opt-out-able coverage — is open, not designed here.
2. **A `string` standard library type**, **console I/O helpers**, and
   **threading helpers** (`thread_create`/`thread_join`/`mutex`/
   `condvar`, §10) — all buildable on v1's primitives, none designed or
   built as part of v1 itself.
3. **Struct field reflection** (querying a struct type's field list at
   compile time, in a form usable for indexing into it) — discussed,
   genuinely wanted, but not designed here: doing this soundly without
   breaking static typing needs its own dedicated design pass, and
   overlaps enough with the polymorphism/type-class work (item 5) that
   it makes more sense to design them together than to bolt a narrow
   version on now.
4. **A general foreign-function interface** — `extern function` still
   names one fixed, Hoare-recognized set of Linux syscalls (v0 §5.2);
   v1 does not open this up to arbitrary external symbols.
5. **Polymorphic (generic) functions and type classes** — noted as a
   clear future direction, no design work done yet; §5.4's operator
   overloading and item 3's struct reflection are both deliberately
   scoped to *not* need this, so that neither has to wait for it.
6. **No macro expansion or conditional compilation of any kind.** v1's
   module system (§6.2) resolves entirely through real grammar
   (`namespace`/`use`/`@autoload`) — there is no preprocessing step left
   at all, and therefore nothing analogous to `#define`/`#ifdef` to
   design either. A textual macro facility remains a plausible, wholly
   separate, later addition, not a gap in the current design.
7. **Any language-level data-race protection.** `sys_clone` (§5.2) makes
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

namespace \Main;

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

(`namespace`/`use`/`@autoload` aren't repeated for each snippet above
since they only matter across multiple files — see §6.2/§6.2a/§6.2b's
own examples.)
