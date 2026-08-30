# Postulate v1.0 language reference

## About this document

This documents the language **Edsger_v0 actually accepts today** —
not the full, eventual v1 language (that's
[postulate_v1_language_reference.md](postulate_v1_language_reference.md),
the target design), and not the older, frozen v0
([postulate_v0_language_reference.md](postulate_v0_language_reference.md)),
which Edsger_v0 is a strict superset of. Every construct below has been
checked against the real, built compiler (`Edsger_v0/build/codegen`,
produced by `Edsger_v0/scripts/build.sh` from `Edsger_v0/src/modular/`)
— not just against the design intent. Where the full v1 reference
already describes a feature identically to how it actually behaves
here, this document says so and points there rather than repeating it;
where behavior differs from that design (a feature not yet implemented,
or implemented more loosely than specified), this document says that
explicitly. **§8 is the single most important section** if you already
know v0 or have read the v1 design doc — it lists everything v1
describes that this compiler does *not* yet do.

If you just want to compile a `.ptl` file, see
[Edsger_v0/README.md](../Edsger_v0/README.md) instead — this document
is the language itself, not the tool.

## 1. Lexical structure

Source text, comments, and identifier rules are **unchanged from v0**
(reference §1.1–§1.3): ASCII `.ptl` files, `//`/`/* */` comments (no
nesting), identifiers `[A-Za-z][A-Za-z0-9_]*`, one flat namespace for
struct/function/extern names shared with the module system (§6).

### 1.1 Keywords

Reserved, cannot be used as identifiers:

```
function struct extern mut const if else while return
namespace use verified unverified
as sizeof lengthof
true false null
int8 int16 int int32 int64 uint8 uint16 uint uint32 uint64 uintptr
bool void char
```

This is v0's keyword set plus `namespace`, `use`, `verified`,
`unverified`, `as`, `sizeof`, `lengthof`, `uintptr`, `char` — the v1
additions this compiler actually implements. `@autoload` is not a
reserved word for the same reason as in full v1: `@` isn't a legal
identifier-start character, so the token can never collide with a name.

**Not reserved here, even though full v1 reserves them**: `pure`,
`ref`, `operator`, `elseif`, `break`, `continue`, `float32`, `float64`,
`float`, `ufloat32`, `ufloat64`, `ufloat` — see §8. `requires`,
`ensures`, `invariant`, `decreases`, `old`, `result`, `last` (full v1's
*contextual* contract keywords) are likewise irrelevant here: the `[
... ]` contract-clause grammar they'd appear in isn't parsed at all
(§8), so these seven are just ordinary, unreserved identifiers.

### 1.2 Literals

**Integer literals** — unchanged from v0 (reference §1.5): decimal
(`42`) or based (`BASEnVALUE`, bases 2/8/10/16 — `16n1F` is 31). Untyped
until context gives them a concrete integer type (§3.6).

**Character literals** — new over v0:

```ebnf
char_literal ::= "'" (char_body | escape_seq) "'"
escape_seq   ::= "\" ("n" | "t" | "r" | "0" | "\" | "'")
```

`'a'`, `'\n'`, `'\t'`, `'\r'`, `'\0'`, `'\\'`, `'\''`. A character
literal's type is always, fixedly, `char` — unlike an integer literal,
it does not adapt to context.

**String literals**: accepted **only** as the `pattern`/`path` operands
of an `@autoload` directive (§6.4) — there is no general string type
(v0 §1.5 still applies: raw bytes are `uint8` arrays), and no other
grammar position accepts a quoted string.

**Boolean/null literals**: `true`, `false`, `null` — unchanged from v0.

**No floating-point literals** — see §8.

## 2. Types

### 2.1 Integer types, `bool`

Unchanged from v0 (reference §2.1–§2.2): `int8/16/32/64`,
`uint8/16/32/64` (`int`/`uint` are aliases for `int32`/`uint32`), and
`bool`. No implicit conversion between any two of these, ever — every
crossing needs an explicit `as` (§3.6a).

### 2.2 `char`

A 1-byte type for a single byte of text, always unsigned (0–255).
**Distinct from `uint8`** — same size, but they do not type-match and
neither implicitly converts to the other; convert explicitly with `as`.
`char` has literal syntax but no arithmetic operators of its own —
`'a' + 1` is a type error. To do byte arithmetic, cast to an integer
type first:

```postulate
mut c : char := 'a';
mut code : uint8 := c as uint8;
code := code + 1;
mut next : char := code as char;   // 'b'
```

### 2.3 Pointers

`*T` — a pointer to a value of type `T`. `&expr`/`*expr` (address-of/
dereference) are unchanged from v0. New over v0, and fully working:

- **Pointer arithmetic**: `p + n`, `p - n` (`p : *T`, `n` any integer
  type) move by `n * sizeof(T)` bytes; `p1 - p2` (same `*T`) gives the
  `int64` element distance between them.
- **`p[i]`** is sugar for `*(p + i)` — this is what makes indexing
  through a bare (non-array-typed) pointer work, not just a true
  `T[N]` array.
- **No bounds checking of any kind**, on either form — an out-of-range
  `p[i]` is undefined behavior, exactly like array indexing already is
  (v0 §2.4). There is no opt-in checked build yet (§8).
- **Comparison** (`== != < > <= >=`) is valid between *any* two pointer
  types, including `*void` — the one exception to the "exact type
  match" comparison rule everywhere else in the language.
- Arithmetic does **not** apply to `*void` directly — cast to a concrete
  pointer type first.

### 2.4 `*void`

The pointer-to-anything type: `sys_mmap`'s return type (§7), and the
common currency for `as`-casting between unrelated pointer types (cast
through `*void`, or directly between two concrete pointer types — both
work, §3.6a). Cannot be dereferenced directly and has no arithmetic of
its own — cast to a concrete `*T` first.

### 2.5 Arrays

`T[N]` — unchanged from v0 (reference §2.4): a fixed-size, stack-local
sequence, `N` a compile-time-constant literal. Indexing (`arr[i]`),
literals (`{1, 2, 3}`), and passing/returning by value (full,
independent copy) all work exactly as in v0.

**Broadcast-init/-assign is not implemented, despite existing in v0
and being real in the v1 design** — see §8. `mut arr : int32[4] := 0;`
is a compile error here (`expected type 'int32[4]', found 'int32'`);
every element needs its own literal: `mut arr : int32[4] := {0, 0, 0,
0};`.

### 2.6 `sizeof`, `lengthof`, `uintptr`

```postulate
sizeof(TypeName)      // : uint64, a type's size in bytes
lengthof(arr)          // : uint64, an array-typed lvalue's element count
```

Both are compile-time constants — no runtime cost, and `lengthof`
requires its operand to already be a genuine array type. `uintptr` is
an unsigned integer type exactly wide enough to hold any pointer on the
target platform (`8` bytes on x86-64) — the only integer type `as` will
convert a pointer to or from (§3.6a); converting a pointer to any
*narrower* integer type is not allowed, to keep address truncation from
ever happening silently.

### 2.7 Structs

Unchanged from v0 (reference §2.6): named fields, packed layout (no
padding), pass/return/assign by full independent value copy, no
self-assignment cycles.

### 2.8 No implicit conversion, anywhere

Unchanged from v0's own rule (reference §2.8), now with one escape
hatch: `as` (§3.6a) is the only way to cross a type boundary. Two
structurally-identical struct types still never match by shape alone —
only by declared name.

## 3. Expressions

### 3.1 Precedence (loosest to tightest)

```
||
&&
== != < > <= >=
|
^
&
<< >>
+ -
* / %
as
unary - ! & * (prefix)
postfix: () [] .
```

Same ladder as v0 (reference §3.1), with `as` inserted between additive
and unary (matching a cast binding tighter than arithmetic but looser
than a bare unary). No `**` (exponent) — that's a floating-point-only
operator not present here (§8).

### 3.2–3.5 Arithmetic, bitwise/shift, comparison, logical operators

Unchanged from v0 (reference §3.2–§3.6): `+ - * / %` require two
same-type integer operands (no operator overloading, §8); `& | ^ << >>`
bitwise; `&& ||` logical with short-circuit evaluation; unary `-`
requires a **signed** integer operand (v1's own deliberate tightening —
negating an unsigned value silently wraps, so it's rejected as a type
error instead); unary `!` requires `bool`.

### 3.6 Untyped constants

Unchanged from v0 (reference §3.7): an integer literal (`0`, `42`, a
literal `-1`, a signed unary-minus literal) adopts whatever integer
type its context requires, checked for range at compile time. `null`
similarly adapts to whatever pointer type is expected.

### 3.6a Explicit conversion (`as`)

```ebnf
cast_expr ::= lvalue "as" type
```

`as`'s left operand **must be an lvalue** (§3.7) — not a call result,
not a bare literal, not a parenthesized arithmetic expression. Bind a
computed value to a local first: `mut tmp := a + b; tmp as int32;`, not
`(a + b) as int32`. A dereference (`*p`) is itself an lvalue, so `*p as
int32` casts the pointed-to value; to reinterpret the *pointer* before
dereferencing, parenthesize: `*(p as *int32)`.

**Allowed conversions**:

| From | To | Notes |
|---|---|---|
| any integer type | any integer type | truncates / sign- or zero-extends |
| integer type | `bool` | nonzero → `true`, zero → `false` |
| `bool` | integer type | `false` → 0, `true` → 1 |
| integer type | `char` | low 8 bits |
| `char` | integer type | zero-extends |
| `*T` | `*U` (any `T`, `U`, including `void`) | reinterprets the address only |
| `*T` | `uintptr` | the raw address |
| `uintptr` | `*T` | the raw address, reinterpreted as a pointer |

Not allowed: pointer to/from any integer type narrower than `uintptr`;
anything to/from a struct or array type. A handful of legal-but-lossy
rows (narrowing between same-signedness integers, signed→unsigned at
any width, unsigned→signed unless the target is strictly wider) produce
a compile-time **warning**, not an error — the cast still runs.

### 3.7 Struct and array literals, function calls, lvalues

Unchanged from v0 (reference §3.8–§3.10): `StructName { field := expr,
... }` (every field named exactly once), `{ expr, expr, ... }` for
arrays (element count must match exactly — no broadcast, §2.5),
ordinary call syntax with left-to-right argument evaluation (a
deliberate v1 choice, differing from v0's own right-to-left order),
lvalues are identifiers, `*lvalue`, `lvalue[expr]`, `lvalue.field`, or a
call/paren-expression that reduces to one of those.

## 4. Statements

### 4.1 Declarations

```postulate
mut name : Type := initializer;
const name : Type := initializer;
```

Unchanged from v0 (reference §4.1) **except**: broadcast-init
(`mut arr : T[N] := scalar;`) does not work here — see §2.5/§8. Every
`mut`/`const` must still come before any other statement in a function
body (v0's `decl* stmt*` rule, unrelaxed).

### 4.2 Assignment

```postulate
lvalue := expr;
lvalue1, lvalue2 := expr1, expr2;   // simultaneous
```

Unchanged from v0 (reference §4.2): every right-hand side evaluates
against the pre-assignment state, then all stores happen together.
**No compound assignment** (`:+ :- :* :/`) and **no broadcast
assignment** — see §8.

### 4.3 `if` / `else`

```postulate
if (cond) { ... } else { ... }
```

Unchanged from v0 — **no `elseif`** (§8); nest a fresh `if` inside the
`else` block instead.

### 4.4 `while`

```postulate
while (cond) { ... }
```

Unchanged from v0. **No `break`/`continue`** — see §8.

### 4.5 `return`, expression statements

Unchanged from v0 (reference §4.5–§4.6).

## 5. Declarations

### 5.1 `struct`

Unchanged from v0 (reference §5.1).

### 5.2 `function`

```postulate
function name(param: Type, ...) : ReturnType {
  ...
}
```

Unchanged from v0's own grammar (reference §5.3) — no `pure`, no `ref`
parameters, no contract clauses (`[requires: ...; ensures: ...;]` isn't
parsed at all — a program that writes one gets a plain parse error, not
a "contracts unsupported" diagnostic). See §8.

### 5.3 `extern function` — the syscall whitelist

Exactly twelve names are recognized, each backed by a real inline-asm
raw-syscall wrapper when declared with a fully pointer/integer-typed
signature (any other extern is only emitted as an unresolvable
`declare`, which will fail to link):

| Name | Signature | Syscall |
|---|---|---|
| `sys_read` | `(fd: int64, buf: *uint8, count: uint64) : int64` | 0 |
| `sys_write` | `(fd: int64, buf: *uint8, count: uint64) : int64` | 1 |
| `sys_close` | `(fd: int64) : int64` | 3 |
| `sys_mmap` | `(addr: uint64, length: uint64, prot: int64, flags: int64, fd: int64, offset: int64) : *void` | 9 |
| `sys_munmap` | `(addr: uint64, length: uint64) : int64` | 11 |
| `sys_mremap` | `(old_addr: uint64, old_length: uint64, new_length: uint64, flags: int64) : *void` | 25 |
| `sys_clone` | `(flags: int64, stack: *void, parent_tid: *int32, child_tid: *int32, tls: uint64) : int64` | 56 |
| `sys_exit` | `(code: int64) : void` | 60 |
| `sys_gettid` | `() : int64` | 186 |
| `sys_futex` | `(addr: *uint32, op: int64, val: uint32, timeout: *void, addr2: *uint32, val3: uint32) : int64` | 202 |
| `sys_openat` | `(dirfd: int64, path: *uint8, flags: int64, mode: int64) : int64` | 257 |
| `sys_exit_group` | `(code: int64) : void` | 231 |

**Important caveat**: the compiler matches by *name* and checks that
every parameter/return is *some* pointer or integer-sized type — it
does **not** yet verify the exact signature above. Declaring
`sys_write` with the wrong argument types will still compile and link,
but will pass whatever you gave it straight into the raw `rdi, rsi,
rdx, r10, r8, r9` syscall registers, unchecked. Match the table
exactly.

**`sys_mremap`'s `flags` must include `1` (`MREMAP_MAYMOVE`)** whenever
the new size might not fit in place — without it, the kernel refuses to
relocate the mapping and returns failure instead, which (being a raw
syscall wrapper with no error-checking layer above it) silently hands
back an invalid pointer. See §7 for the canonical grow-a-buffer pattern.

## 6. Program structure

### 6.1 `namespace` (mandatory, first)

```postulate
namespace \Some\Path;
```

Every `.ptl` file starts with exactly one of these — a file with none,
or one that isn't first, is a compile error ("missing namespace").
There is no default/global namespace.

### 6.2 `use`

```postulate
use \Some\Path;
use \Some\Path as Alias;
use \Some\Path\{ItemA, ItemB as C};
```

All three forms **parse**. In this implementation, though, symbol
visibility is effectively **global and flat** once a file has been
discovered and read: declaring `use` (in any form) is what causes the
compiler to locate and read the referenced file, but a struct/function
name declared anywhere in the whole program is then visible everywhere,
by its own original name — `use ... as Alias` does not actually make
`Alias.Thing` a valid way to refer to it, and omitting a `use` entirely
for a namespace whose file has already been pulled in some other way
does not hide its names either. Write `use` for every namespace whose
*file* you need read; don't rely on aliasing or on `use`'s absence to
scope anything.

### 6.3 File discovery

With no `@autoload` involved, a fully-qualified name's every segment
except the last becomes a directory, and the last becomes a filename
with `.ptl` appended: `\Core\Math\Matrix` → `Core/Math/Matrix.ptl`,
resolved relative to **the compiler process's own current working
directory** — not the entry file's location, and not configurable via
a command-line flag. This is the reliable, well-tested path; run the
compiler from the directory that contains your namespace tree's own
root.

### 6.4 `@autoload`

```postulate
@autoload "\Vendor\Math\" => "third_party/mathlib/src";
```

Legal only in the file that declares `\Main`. Parses and is read by the
compiler's own file-discovery pass; the default 1:1 rule above is the
path this has actually been exercised against. If you need a
non-default layout, test it directly against your own project before
relying on it.

### 6.5 `main`

```postulate
namespace \Main;
function main() : int32 { ... }
```

Zero-parameter form only — the two-parameter `main(argv, argc)` form
from the v1 design is not implemented (§8). Whichever file declares
`main` gets the process's real ELF entry point (`_start`) emitted for
it automatically; `main`'s return value becomes the process exit code
via `sys_exit_group`.

## 7. A worked example — heap-backed growable buffer, and I/O

```postulate
namespace \Main;

extern function sys_write(fd: int64, buf: *uint8, count: uint64) : int64;
extern function sys_mmap(addr: uint64, length: uint64, prot: int64, flags: int64, fd: int64, offset: int64) : *void;
extern function sys_mremap(old_addr: uint64, old_length: uint64, new_length: uint64, flags: int64) : *void;
extern function sys_munmap(addr: uint64, length: uint64) : int64;

struct Buf {
  ptr : *uint8;
  cap : uint64;
  len : uint64;
}

function buf_new(initial_cap: uint64) : Buf {
  mut raw : *void := sys_mmap(0, initial_cap, 3, 34, 0, 0);
  return Buf { ptr := raw as *uint8, cap := initial_cap, len := 0 };
}

function buf_grow(b: *Buf, new_cap: uint64) : void {
  mut raw : *void := sys_mremap((*b).ptr as uintptr, (*b).cap, new_cap, 1);
  (*b).ptr := raw as *uint8;
  (*b).cap := new_cap;
}

function buf_push(b: *Buf, byte: uint8) : void {
  if ((*b).len == (*b).cap) {
    buf_grow(b, (*b).cap * 2);
  }
  (*b).ptr[(*b).len] := byte;
  (*b).len := (*b).len + 1;
}

function main() : int32 {
  mut b : Buf := buf_new(4);
  mut i : uint64 := 0;
  while (i < 10) {
    buf_push(&b, 65 + (i as uint8));
    i := i + 1;
  }
  sys_write(1, b.ptr, b.len);
  sys_munmap(b.ptr as uintptr, b.cap);
  return 0;
}
```

Compiling and running this (see [Edsger_v0/README.md](../Edsger_v0/README.md)
for the `edsger` CLI) prints `ABCDEFGHIJ` and exits `0`. It exercises
`*void`/pointer-arithmetic/`uintptr` casts, the raw-syscall extern
whitelist, structs, and simultaneous-assignment-free but otherwise
ordinary control flow — the full working core of this language.

## 8. What v1.0 does not yet implement

Everything below is real, designed v1 (see the full
[v1 reference](postulate_v1_language_reference.md)) but **not present**
in Edsger_v0 today — each confirmed against the real compiler, not
assumed from the design docs:

- **Array/struct broadcast-init and broadcast-assignment** (`mut arr :
  T[N] := scalar;`) — despite existing in v0 and being carried forward
  in the v1 design, this compiler's Sema/Codegen never implements it
  (§2.5). Every element needs its own literal.
- **Statement sugar**: `elseif`, `break`/`continue`, compound
  assignment (`:+ :- :* :/`), `++`/`--`.
- **Floating point**: `float32/64`, `ufloat32/64`, `**` (exponent), and
  every literal/operator/cast row involving them.
- **`ref` parameters** and **operator overloading** (`operator + (...)`).
- **`pure` functions and the entire verification-contract system**
  (`[requires: ...; ensures: ...;]`, loop `invariant`/`decreases`,
  `old`/`result`/`last`) — the contract-block grammar itself isn't
  parsed; writing one is a plain parse error, not a graceful
  "unsupported" diagnostic.
- **Static verification** (`postulate verify`, the Why3 path) and the
  **opt-in bounds-checking diagnostic build** — neither tool/mode
  exists.
- **`main(argv, argc)`** — only the zero-parameter form works.
- **Extern-signature validation** — see §5.3's caveat; a
  wrong-but-plausible-looking syscall signature is not caught.
- **True `use`/namespace scoping** — see §6.2; resolution works, but
  visibility is flat, and aliasing/group-import syntax is accepted
  without being semantically meaningful yet.

None of this is a promise about when (or whether) each lands — see
`docs/postulate_stage1_bootstrap_plan.md` for the actual, live roadmap.
This section exists so a program that needs one of these gets a clear
"not yet" here rather than silent surprise against the full v1 design
doc.
