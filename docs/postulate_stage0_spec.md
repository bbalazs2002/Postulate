# Postulate — Stage 0 Language Specification

> This document contains all the information needed to build the **Postulate**
> language's Stage 0 bootstrap compiler. Its purpose is to allow development to
> continue in a different session, without prior history.

---

## 1. Project context

Postulate is a **custom-designed, C-like programming language**, whose purpose
is to write a custom, modular, multi-architecture hobby operating system. The
language's main design goal is **not** maximal expressiveness or convenience,
but rather:

1. To be suitable for **mathematically precise, specification-level correctness
   proofs** (Hoare logic, based on the relational model from ELTE IK's
   "Introduction to Programming" course / Ákos Fóthi's model — state space,
   parameter space, pre-/postcondition, weakest precondition).
2. To reflect this formal, pseudocode-like way of thinking in its syntax as well.
3. To be suitable for both imperative **and** functional-style use.
4. To be suitable for kernel development (systems programming): no GC, no
   hidden runtime overhead, explicit memory management.

### Name selection

The language's name is **Postulate**. Rejected candidates and their reasons:
- `N` — taken (N-lang, ALGOL N)
- `Nerd` — taken, active, recent project (LLM-native language, nerd-lang.org)
- `Axiom` — taken (well-known computer algebra system)
- `QED` — taken (multiple projects, one of them specifically in the formal
  verification space)
- `Certus` — partially taken (2025 publication, assurance-case DSL)
- `Verus` — taken (significant, active Rust verification tool)
- `Praecis` — was free, but phonetically close to "Praxis" (the name of a
  predecessor company of SPARK Ada), so it was dropped

`Postulate` is free, and its meaning (a postulate is a statement accepted
without proof, serving as a foundation) fits the verification goal. Bonus: it
resembles the Hungarian word "pusztulat" [destruction/ruin] (a self-ironic nod
to the language's strictness/difficulty).

### File extension

**`.ptl`** — there is a mild, but negligible, clash: the IBM Rational Rose
"Petal" UML file format (inactive tool), and the Python Quixote template
language (obsolete). Neither is an active programming language, so the
practical risk is judged low and accepted.

---

## 2. Bootstrap plan (big picture)

```
Stage 0 (assembly, x86_64, Linux host)
   │  compiles the Stage 1 source code
   ▼
Stage 1 (written in the Postulate language, generates LLVM IR target code)
   │  self-hosting: Stage 1 compiles itself
   ▼
Self-hosting achieved — Stage 0 (the "bootstrap core") becomes historical/disposable thereafter
```

- **Stage 0's sole purpose** is to be able to compile the Stage 1 compiler
  (which is already written in the Postulate language itself). It does not
  need to support the full language — only a minimal, well-defined subset
  (this is the subject of the present document).
- **Starting from Stage 1**, the compiler generates LLVM IR, taking advantage
  of LLVM's ready-made, mature backends for every target architecture
  (x86_64, ARM, RISC-V, etc.) — so there is no need to write a custom codegen
  for every architecture.
- **Host environment:** the developer's machine runs Windows 11 x64, but the
  Stage 0/Stage 1 compilers run **on a Linux x86_64 host** (via Docker), to
  match the syscall environment of GitHub Actions CI (ubuntu-latest). Stage 0
  assembly accesses the **Linux x86_64 syscall ABI** (System V AMD64 calling
  convention) directly — there is no libc, no dynamic linking, it is a static,
  syscall-based binary.
- Stage 0/Stage 1 **run on the developer's (host) machine**, not on the
  eventual custom OS — that does not exist yet when you run the compiler.
  Therefore Stage 0 must provide its own I/O and memory allocation (via the
  `mmap`, `read`, `write`, `exit` syscalls), without libc.
- **The Postulate language itself also accesses these same syscalls**, via
  `extern function` declarations (see chapter 4 grammar) — without this, the
  Stage 1 compiler (which is already written in Postulate) would not be able
  to read a source file or write out LLVM IR. The Stage 0 compiler recognizes
  a **fixed, closed list of symbol names** and compiles them directly into
  syscall invocations — there is no general linker/FFI:

  ```postulate
  extern function sys_read(fd: int64, buf: *uint8, count: uint64) : int64;
  extern function sys_write(fd: int64, buf: *uint8, count: uint64) : int64;
  extern function sys_mmap(addr: uint64, length: uint64, prot: int64,
                            flags: int64, fd: int64, offset: int64) : *uint8;
  extern function sys_exit(code: int64) : void;
  ```

---

## 3. Stage 0 — what it includes and what it doesn't

### What it includes (with rationale)

Stage 0 includes exactly as much as is needed to write a **lexer + recursive
descent parser + AST construction + textual LLVM IR emission** for compiling
the Stage 1 compiler:

- Fixed-size integer types, `bool`, raw pointer, fixed-size array (elements of
  a base type or pointer), `struct`, `void`
- Only function-start declarations (fixing the state space — Hoare-logic
  friendly)
- `if`/`else`, `while`, `return`
- Simultaneous assignment (`:=`), with Dijkstra/Hoare semantics
- A complete expression grammar with operator precedence
- Multi-radix integer literals, `bool` literal, `null`
- `//` and `/* */` comments
- `extern function` declaration, with a fixed syscall whitelist — this is what
  makes it possible for the Stage 1 compiler (written in Postulate) to read
  and write files at all; without it the bootstrap chain could not proceed to
  Stage 1

### What is intentionally excluded from Stage 0

- Generics, closures, exception handling, OOP (inheritance, dynamic dispatch), GC
- Standard library, string type, char type, float type
- Verification contract syntax (`requires`/`ensures`/invariant) — this will be
  the language's *main* goal, but it only appears starting from Stage 1
- Multi-file module/include system
- Pass-by-reference parameter passing (only by value, see below)
- The `**` exponentiation operator (see "Decisions deferred to later phases")

---

## 4. Complete formal grammar (EBNF) — Stage 0

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
```

The alternatives of the `type` rule are to be understood **in order, with a
first-match rule** (PEG-style) — the first alternative always takes priority
if it matches:

- **`*T[N]` (without parentheses) → an array of N `*T` pointers.** This is the
  short, default form — for compiler data structures (AST child lists, symbol
  table entries) this is the more common case.
- **`*(T[N])` (with explicit parentheses) → a pointer to an N-element array of
  `T`.** The rarer case requires parentheses — made possible by the grouping
  rule `"(" type ")"`.
- Without parentheses, `*` always applies to the *element immediately
  following it, not yet decomposed* — if that immediately forms a
  `base_type "[" N "]"` pattern, the whole `*base_type[N]` unit must be read
  as an "array of pointers", not as an "array wrapped into a pointer".

```ebnf

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

### Semantic constraints (not grammatical — to be checked in the compiler's
semantic analysis phase, not at the lexer/parser level)

| Area | Rule |
|---|---|
| Numeral system base | The base of `based_form` can only be `{2, 8, 10, 16}`; every `value_digit` must be smaller than the base. **The grammar is deliberately more permissive than the semantics** — the set of allowed bases can be extended later by modifying the semantic analyzer, leaving the grammar unchanged. |
| Declaration location | Only at the very start of `func_block` — nested blocks (`if`/`while` bodies) may not contain a `decl`. This is already excluded at the grammar level by the separate `func_block` vs. `block` rules. |
| Parameter passing | Always **by value** in Stage 0 (no pass-by-reference). |
| `const` | Requires mandatory inline `:=` initialization; a `const` identifier may **never** be an `lvalue` target in an `assign_stmt`. |
| `mut` (scalar type) | Optional inline initialization; can be reassigned arbitrarily. |
| `mut`/`const` (array type) | **Mandatory** `:=` initialization; the value is a single expression that is **broadcast to every array element**. E.g. `mut arr : int32[10] := 0;` → all 10 elements are 0. |
| `mut`/`const` (struct type) | **Mandatory** `:=` initialization, exclusively in `struct_literal` form. |
| `struct_literal` | Must specify **every** field of the referenced `struct` exactly once, explicitly — a missing or duplicated field is a compile error. Goal: an uninitialized ("garbage") struct instance can never come into existence. |
| `comparison` | **Not chainable** — `a < b < c` is grammatically invalid (marked by `?` in the grammar: at most one comparison operator). This is a deliberate departure from mathematical convention, to avoid C's inherited, misleading chaining behavior. |
| `int` / `uint` | `int` ≡ `int16`, `uint` ≡ `uint16` — fully equivalent underlying types, not separate types. |
| Implicit type conversion | **Forbidden.** Both operands of a binary operator must be of strictly identical type (e.g. `int8 + int32` is a compile error). This eliminates complex implicit coercion/zext/sext logic from the Stage 0 code generator, and is consistent with the language's core "explicit in everything" convention. |
| `array_literal` | The number of elements must exactly match the declared array size (`N`). Any mismatch is a compile error — an intermediate, partial list is not allowed (the same "no garbage memory" principle as with structs). The compiler internally desugars the list into a sequence of indexed assignments (`arr[0] := e0; arr[1] := e1; ...`), with no separate code generation case for it. |
| Pointer arithmetic | **Forbidden in Stage 0.** Only address-of (`&`) and dereference (`*`) are allowed on pointers — expressions in the style of `p + 1` result in a compile error. Array access in the form `arr[i]` remains supported. This restriction **will be lifted in a later phase** — see "Decisions deferred to later phases". |
| Simultaneous assignment | In an `assign_stmt`, every `lvalue` target must be distinct within a single line. The right-hand sides are evaluated against the state **before** the statement; all assignments only take effect afterward, simultaneously (Dijkstra/Hoare semantics). |
| `extern function` | The declared name may only be chosen from the **fixed, closed list of symbol names** known to the Stage 0 compiler (see the addendum to chapter 2) — currently `sys_read`, `sys_write`, `sys_mmap`, `sys_exit`. The parameter and return types must exactly match the signature fixed for that symbol in Stage 0. There is no `func_block` body (it is closed by `;`), and there is no general linker/FFI — an `extern` declaration under any other name is a compile error. |
| `return` / return type | In a function with `void` return type, `return` may only appear without an expression (`return;`). For every other (non-`void`) return type, `return` must include an expression, whose type must strictly match the function's declared return type — the same "Implicit type conversion: forbidden" rule applies here as well (see above), so e.g. an expression returning `int16` is not acceptable for an `int32` return type. Every execution path in a non-`void` function must end with a `return`. |

### Operator precedence and associativity (the order of the grammar chain
already reflects this, from strongest to weakest)

| Level (strong→weak) | Operators | Associativity |
|---|---|---|
| `postfix` | `[]`, `.`, `()` | left |
| `unary` | `!`, `-`, `*` (dereference), `&` (address-of) | right (prefix chain) |
| `multiplicative` | `*`, `/`, `%` | left |
| `additive` | `+`, `-` | left |
| `shift` | `<<`, `>>` | left |
| `bit_and` | `&` | left |
| `bit_xor` | `^` | left |
| `bit_or` | `\|` | left |
| `comparison` | `==`, `!=`, `<`, `>`, `<=`, `>=` | **not chainable** |
| `logic_and` | `&&` | left |
| `logic_or` | `\|\|` | left |

**Important:** bitwise operators bind tighter than comparison (Python-style)
— this deliberately reverses the classic C pitfall, where e.g. `e & 1 == 1` is
interpreted as `e & (1 == 1)`. In our case, `e & 1 == 1` ≡ `(e & 1) == 1`.

---

## 5. Design decisions — with rationale (quick reference)

- **`:=` for assignment, not `=`** — follows the ELTE programming-theory
  (Dijkstra/Hoare) notational tradition; literally matches the notation of
  Ákos Fóthi's book *Introduction to Programming*.
- **Only `mut` and `const`, no `let`** — `let` would have been redundant,
  since the goal is only two kinds of variable (freely modifiable / constant).
- **Declaration only at the start of a function** — fixes the "state space"
  for the entire body of the function, making Hoare-triple-based proofs
  easier.
- **`function name(params) : type { }`** — not `fn`/`->`, but `function`/`:`.
- **No hyphens in identifiers** — this would clash with the subtraction
  operator (`a-b` would be ambiguous under maximal-munch matching); only `_`
  is allowed.
- **C-style comments** (`//`, `/* */`).
- **Multi-radix literals in `BASEnVALUE` form** (e.g. `16n1F`), not `0x`/`0b`
  prefixes — this leaves room for future base expansion; only the semantic
  analyzer needs to be modified, not the grammar.
- **`^` remains bitwise XOR**, not exponentiation — exponentiation will be
  introduced via `**`, but **later**, not in Stage 0 (see below).
- **Array size uses postfix notation** (`int32[10]`, not `[10]int32`).
- **Struct and array declarations require full initialization** — there is no
  composite value with "garbage" memory content; this is also mathematically
  consistent with Fóthi's book's definition of records (the record *is*
  itself the complete n-tuple of components, and conceptually cannot exist
  partially filled).
- **`void` return type, as a separate `return_type` rule** — usable
  exclusively as a function's return type, not part of the general `type`
  rule, so it cannot be the type of a variable, field, or parameter. This is
  needed for functions that are called only for a side effect (e.g. writing
  through a pointer) and have no meaningful return value.
- **`*T[N]` defaults to "array of N pointers", not "pointer to an array"** —
  for compiler data structures (AST child lists, symbol table) an array of
  pointers is the more common case, so it gets the short form; the rarer
  "pointer to an array" case is marked by explicit parentheses (`*(T[N])`).
- **`extern function`, with a fixed syscall whitelist, not a `syscall()`
  primitive or an `asm` block** — the essence of Hoare-logic-based, modular
  proof is that a function call can be checked based on its *contract*
  (typed signature, later `requires`/`ensures`) without needing to look into
  its body. A typed, named `extern` declaration is exactly that — a "black
  box" with a contract. A raw `syscall(nr, args...)` call would scatter the
  semantics across untyped call sites, and an `asm` block would be completely
  opaque to any static/formal analysis — both would work against the
  provability goal.

---

## 6. Decisions deferred to later phases (not Stage 0)

1. **UTF-8 source code encoding support** — Stage 0 is ASCII-based for now,
   but Postulate must eventually support UTF-8 (not just ASCII).
2. **The `**` exponentiation operator**, right-to-left associative
   (`2**3**2 = 2**(3**2)`), with `^` remaining reserved for XOR. There is no
   native x86_64 integer exponentiation instruction — it must be implemented
   in software, via repeated squaring (exponentiation by squaring), once
   introduced.
3. **Pass-by-reference parameter passing** — in Stage 0 every parameter is
   passed by value. Later, pass-by-value will remain the default, but
   pass-by-reference will also become available via explicit notation (syntax
   still to be worked out).
4. **Pointer arithmetic** — forbidden in Stage 0 (only `&`/`*` allowed), but
   will be introduced in a later phase. The manner of introduction (e.g. only
   type-size-scaled stepping, or raw byte offsets) is still to be worked out.
5. **Warning for an ignored return value** — the final (non-Stage-0) compiler
   must issue a separate diagnostic warning (not an error) if a program calls
   a function with a non-`void` return type as an `expr_stmt` without using
   the returned value (e.g. `mult(4);` as a standalone statement). The
   introduction of the `void` return type (see chapters 4–5) makes exactly
   this distinction explicit: a function either declaredly returns no value
   (`void`, nothing to discard), or it does, and discarding it is likely a
   bug in the calling code.
6. **Function declaration without a definition (forward declaration)** — the
   `function` rule currently always requires a `func_block` body, so there is
   no way to merely declare a function to be implemented in Postulate and
   supply the body later (e.g. for mutually recursive functions, or so that
   call order does not constrain definition order). This is **not** the same
   as `extern function` (see chapters 2–4) — that is a declaration known to
   Stage 0, mapped to a syscall, permanently bodiless; this would be a
   deferred body for a function written in the Postulate language. The exact
   syntax (e.g. `function name(params) : return_type;` without a body,
   followed by a separate `function name(params) : return_type { ... }` with
   the actual definition, with the two signatures required to match) is still
   to be worked out.

---

## 7. Open questions, not yet finally decided

- **String/char type** — deliberately absent in Stage 0; the Stage 1
  lexer/parser handles text as raw `uint8` bytes. To be reconsidered later,
  once the language is extended.
- **`postfix_op` as a separate rule** — must be treated as a separate AST node
  type both grammatically and **in code generation** (not merged with the
  `postfix` rule) — this was an explicit request, keep it during
  implementation.

*(The array literal (`array_literal`) was previously an open question, now
finalized — see the grammar in chapter 4 and the `array_literal` row of the
semantic table in chapter 5.)*

---

## 8. Formal background — correspondence with the relational model of Ákos
Fóthi's book *Introduction to Programming*

The language's constructs can be traced directly back to the book's
formalism — this will be the basis of the proof apparatus once the
verification syntax (Stage 1+) is introduced:

- **`while_stmt`** ≡ the book's `DO(π, S0)` construct (sections 6.3, 7.3) — the
  loop derivation rule (invariant `P`, terminating function `t`) applies
  directly.
- **`assign_stmt`** (simultaneous assignment) ≡ the book's definition 8.4
  (Elementary programs — Assignment), literally the same `:=` notation and
  semantics.
- **`struct`** ≡ the book's "record" type construct (sections 11.1–11.2) —
  selector functions (`t.si`), field assignment (`t.si := ti`) match exactly.
- **`if`/`else`** is a deterministic, two-branch, exhaustive special case of
  the book's more general, nondeterministic `IF(π1:S1,...,πn:Sn)` construct
  (sections 6.2, 7.2). An `if` without `else` corresponds to
  `IF(π: S, ¬π: SKIP)`, where `SKIP` is the identity program per the book's
  definition 8.2.
- Deliberately **not** adopted: `ABORT` (never terminates), value selection
  (`:∈`, nondeterministic) — these are needed for the relational model's
  handling of nondeterminism, but are not needed for the target language of
  an actual, deterministic compiler.

---

## 9. Sample program (per the most recently agreed syntax)

```postulate
// Syntax demonstration for the Postulate language.

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

  // Simultaneous assignment: the right-hand sides are evaluated in the original state
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
  // All declarations at the start of the block (func_block ::= decl* stmt*) —
  // only statements may follow after that.
  const pair : Pair := Pair { a := 8n17, b := 16n1F };
  const total : uint := 16n64;            // uint ≡ uint16

  mut n2 : Node := Node { value := 99, next := null };
  mut n1 : Node := Node { value := 1,  next := &n2 };

  // array of pointers: 3 *Node entries, all broadcast to null by default (see chapter 4)
  mut node_list : *Node[3] := null;

  mut arr : int32[10] := 0;               // every element initialized to 0

  // array_literal: exactly 10 elements, an arbitrary expr (e.g. a function call) is also allowed
  mut arr2 : int32[10] := {1, 2, 3, 4, 5, 6, 7, mult(4), 9, 10};

  mut p   : *int32 := &arr[0];            // address-of only, independent of arr's contents
  mut sum : int32;                        // scalar mut: optional initialization

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

  increment(&sum);   // void function: side effect via pointer, no return value

  sys_write(1, &msg[0], 5);   // extern function: raw syscall call

  return sum;
}
```

---

## 10. Next step (where the design was left off)

The Stage 0 grammar can be considered **formally closed** (except for the open
questions noted in section 7, which do not block getting started) — including
the array-of-pointers notation and the `extern function`/syscall whitelist,
which had previously blocked the Stage 1 self-hosting compiler from actually
being written (see chapters 2–5). The logical next steps in a new session are:

1. Begin implementing the lexer in x86_64 assembly (Linux syscall ABI), based
   on the `identifier`/`literal`/`comment`/`keywords` rules above.
2. Build a recursive descent parser based on the EBNF above.
3. Set up GitHub Actions CI (QEMU + Docker-based build environment) — this was
   the topic of an earlier discussion for this project not covered by this
   document; worth summarizing separately if needed.
