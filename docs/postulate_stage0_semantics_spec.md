# Postulate Stage 0 — Semantic Analyzer Technical Specification

> This document is the technical specification for the Stage 0 bootstrap
> compiler's **semantic analyzer** — in three passes: **Phase 1** (name
> resolution + basic type checking), **Phase 2** (array/struct literal
> completeness, based-form digit-range validation, "every execution path
> ends with a return" control-flow analysis), and **Phase 3** (array
> broadcast-init, compile-time array-index range checking — both found
> while designing Phase 2 of the code generator, already implicitly
> present in the main spec but so far missing from the checker). Phase 3
> completes coverage of the full semantic rule list in the main spec,
> with the exception of the two items explicitly marked there as beyond
> Stage 0's scope (see chapter 10). Its prerequisites are
> [postulate_stage0_spec.md](postulate_stage0_spec.md) (grammar, chapter
> 4 "semantic constraints") and
> [postulate_stage0_parser_spec.md](postulate_stage0_parser_spec.md) (the
> already-completed parser covering the full grammar — everything
> described here builds on its `parse_program` output). The goal is a
> **third, standalone `build/checker` binary** — continuing the
> `lexer → parser → checker` layering; the Stage 0 bootstrap compiler's
> final name will be **Hoare**, but this pass is not yet the final,
> unified `hoare` command-line tool, only an intermediate building block
> of it.

---

## 1. Goal and scope

The "Semantic constraints" table in chapter 4 of the main spec lists 16+
rules that the parser deliberately does not check (the principle "the
parser permits, semantics rejects"). Continuing the parser's own
disciplined, incremental development approach, this was implemented in
two passes.

**Implemented in Phase 1** (the foundation everything else builds on):
- Top-level name registration (struct/function/extern), duplicate names
  forbidden.
- Extern-whitelist validation (name + exact signature match).
- Per-function flat local symbol table (params + decls), duplicates
  forbidden.
- Identifier resolution (identifier → local; call → global callable).
- Type resolution (validity of struct-name references everywhere a type
  appears: field, parameter, return type, local decl).
- Binary/assignment/return/call-argument type matching (`int`≡`int16`,
  `uint`≡`uint16` folding).
- Field- and index-access validity (struct/array/pointer shape).
- `lvalue`-shape checking for assignment targets and for `&`.
- Prohibition of `const` reassignment (except writes through a pointer).
- Simultaneous-assignment target uniqueness (by syntactic identity).
- `if`/`while` condition must be `bool`.
- Array-/struct-literal **per-element** type propagation (completeness
  checking deferred at this point).

**Implemented in Phase 2** (see chapters 7.4/7.5/8.1 for details):
- Array-literal element count matches the declared array size exactly.
- Every field of a struct literal appears exactly once (both duplicate
  and missing fields are errors).
- Based-form digit range: the base must be one of `{2, 8, 10, 16}`, every
  digit must be `< base`.
- "Every execution path ends with a return" in non-`void` functions.

**Implemented in Phase 3** (see chapters 7.6/8.2 for details):
- Array broadcast-init: broadcasting a single scalar initial value/value
  to every element, if its type matches the array's element type.
- Compile-time range checking of array indices for bare integer-literal
  indices.

**Deliberately left beyond Stage 0** (marked as such in the main spec
too — not deferred but excluded outright from this compiler, see
chapter 10): the "ignored return value" warning, forward-declared
(bodyless) functions.

---

## 2. Three open questions in the language specification — settled here

During design/implementation, three points emerged that the main spec
does not state explicitly. All three were settled (with rationale for
the decision), but it would be worth adding them to the main spec as
well — that has not been done in this pass, they are only recorded here.

### 2.1 Literal typing

The grammar has no literal suffix (there is no `5i32`-style notation),
so a bare `5` cannot have a fixed type on its own — while the "Implicit
type conversion: forbidden" rule requires every expression to have an
*exact* type for comparison purposes. The only viable reading (and the
only one consistent with the main spec's own sample program, where bare
literals are placed into fields of different sizes): the
**contextual/untyped constant** model, following Go's example — `int`/
`bool`/`null` literals have no fixed type of their own; `check_expr`
takes an `expected_type` parameter, which is **only** actually consumed
by literals.

### 2.2 The formal `lvalue` rule does not cover the `(*arr)[i]` form

`lvalue ::= "*" lvalue | identifier ("[" expr "]" | "." identifier)*` —
this only allows `*` to precede **another `lvalue`**, not a
parenthesized-then-indexed expression. But `(*arr)[i] := ...` is exactly
the pattern that the `*(T[N])` pointer-to-array design decision
(expression-parser phase) enables, and one that the black-box test suite
uses throughout. The parser already accepts it (permissive design,
semantics decides). **This phase structurally defines "valid lvalue"**,
not by the letter of the grammar: any expression built **exclusively**
from `IDENT`/`UNARY(*)`/`INDEX`/`FIELD` nodes, ultimately terminating in
a bare identifier — this naturally accepts `(*arr)[i]` as well.

### 2.3 Interaction of `const` and `*`

Is `*p := 5;` an error if `p` is a `const` pointer? Reassigning `p`
itself would be an error, but writing through it is a different case —
Stage 0 has no separate `const T` vs. `T` type qualifier; `const` is a
one-time-assignment property of the **binding**, not of the pointee
value. Rule: walking the `lvalue` chain from outside in, if a `*`
dereference occurs **before** reaching the base identifier, this is
"write-through-pointer" — the `const` status is irrelevant from that
point on. Only a chain that reaches the base identifier **without** a
deref receives `const` checking.

---

## 3. Architecture: `build/checker` (a third, standalone binary)

Same layering as lexer→parser: the checker links the entire existing
parser/lexer code (`lexer.asm`, `parser_tokens.asm`, `type_parser.asm`,
`expr_parser.asm`, `stmt_parser.asm`, `top_parser.asm`, `ast.asm`,
`runtime.asm`), but does **not** link `ast_dump.asm` (not needed — on a
successful run the checker only prints `OK`, not an AST dump).

The `checker_main.asm` driver is **not** directive-based (unlike
`parser_main.asm`'s test driver) — it reads the entire stdin as a single
`program` and checks it, because checking always applies to the whole
program. Of the binaries built so far, this is the closest to how the
final `hoare` command-line tool will receive a `.ptl` file.

**Exit codes**, extended:

| Code | Meaning |
|---|---|
| `0` | Success — `OK\n` to stdout. |
| `1` | Lexical/syntax error (unchanged, inherited from the parser). |
| `2` | Resource-related error (unchanged). |
| `3` | **New: semantic error.** `semantic error: <message> at line L, col C (byte offset O)` to stderr. |

---

## 4. No new AST node — with one exception

Symbol tables and type checking form a **read-only** traversal over the
existing AST — no new `AST_*` kind, no annotation written back, no
persistent "decorated AST" (nothing consumes one yet — a future
code-generation phase may decide whether it needs a persistent type
annotation or will re-run inference; that decision is **not** made in
this phase).

**The single exception:** `AST_EX_INT`/`AST_EX_BOOL`/`AST_EX_NULL`
originally only stored the value (`a` field; `b`/`c`/`d` unused) —
unlike the other "named" nodes (`AST_EX_IDENT`, the `AST_TY_BASE`
name-reference case), it did not retain the source span. Diagnosing a
type error centered on a literal (e.g. `if (5) { ... }`) **requires**
some position. Fix: `AST_EX_INT`'s `b`/`c` fields are now `name_offset`/
`name_len` (alongside the value that stays in `a`); `AST_EX_BOOL`/
`AST_EX_NULL`'s `a`/`b` (respectively `b`/`c`) fields are the same —
additive, non-breaking change (`dump_expr`'s `.int`/`.bool`/`.null`
cases do not read these fields, so no changes were needed there). The
`.int`/`.true`/`.false`/`.null` branches of `expr_parser.asm` gained a
few extra `mov`s **before** `parser_advance`, so the token is not lost.

**A second, similar addition:** the `b` field of `AST_STMT_RETURN` is
now the `return` keyword's own source offset — the only statement kind
that needed this, because the "missing return value" error (`return;`
in a non-`void` function) has no expression to hang the diagnostic
position on, and no other field offers an alternative.

---

## 5. Symbol tables (`symtab.asm`)

There is no nested scope to model: Stage 0 only allows `decl` at the
start of a `func_block` (never inside an `if`/`while` body) — so there
is **exactly one** flat scope per function (its params + its own decls),
with no shadowing rule. All three tables are flat, `MAX_LIST_ARITY`-bounded
arrays with linear search — the same pattern as every other
variable-arity list in the codebase (`symtab.inc` fixes the record
layouts, shared between the writer `symtab.asm` and the readers
`sema_expr.asm`/`sema_stmt.asm`).

- **Global table**, built once per `AST_PROGRAM` in two sub-passes, so
  that declaration order and mutual/forward references (a function
  calling a function declared later, a self-calling `gcd`, a struct
  referencing a struct declared later) work regardless of order:
  - *Pass 1a — register names*: `struct_table` (`{name_offset,
    name_len, AST_STRUCT_DECL ptr}`), `callable_table` (`{name_offset,
    name_len, is_extern, AST_SIGNATURE ptr, return_type ptr}` —
    function+extern unified, both are equally "callable by name").
    Duplicate checking happens in **one shared namespace**, struct +
    function + extern together (a simplifying, revisitable decision —
    not a language requirement).
  - *Pass 1b — resolve every declared type*: every type occurrence
    (struct fields, parameters, return types) runs through
    `resolve_type`, once every name is known.
  - *Pass 2 — check every function body*, now with the complete global
    table.
- **Local table**, rebuilt per function: a flat `{name_offset,
  name_len, type ptr, is_const}` list from the signature's params plus
  the `func_block`'s decls. Duplicate-checked the same way (param/param,
  param/decl, decl/decl — nothing to shadow). **This is also where** each
  local decl's own type is resolved (not in pass 1b — it only needs to
  be valid when that function's body is being checked, not earlier).
- **Lookup**: linear scan + `bytes_equal` (a local copy of the pattern
  known from `parser_main.asm`, following the codebase's convention of
  duplicating small helper functions per file).

---

## 6. Types (`sema_types.asm`)

A "type" here is simply a pointer to an already-existing `AST_TY_*`
node — most often a node already sitting in the AST (a decl's own type,
a symbol-table entry's type), occasionally freshly synthesized
(`get_bool_type`/`get_int_type`/`get_null_default_type` canonical
singletons, or the result type of `&x` in `sema_expr.asm`) — via
`ast_alloc_node`.

- **`resolve_type`**: recursive validity checking — `POINTER` recurses
  into its inner type, `ARRAY` into its element type, a built-in `BASE`
  is always valid, a struct-name `BASE` (tag=0) is looked up in the
  global struct table, error if not found.
- **`types_equal`**: structural comparison, with `int`≡`int16` /
  `uint`≡`uint16` folding (the main spec's "int/uint" row — different
  `TOK_KW_*` tag, same underlying type); struct-name `BASE`s compared by
  name span; `ARRAY` additionally requires element-count equality.
  **`0` ("void") is never equal to anything on either side** — this
  constraint uniformly closes off the case where the result of a `void`
  return-type call is used as a value (see chapter 7).

---

## 7. Expression checking (`sema_expr.asm`)

`check_expr(node, expected_type) -> resolved type ptr` — one large
dispatcher, following `dump_expr`'s per-node-kind shape, but computing
and checking instead of formatting. `expected_type` is only actually
consumed by literals (`INT`/`BOOL`/`NULL`) and by `array_literal`
(which learns its element type from it, since it carries no type
annotation of its own).

For binary/arithmetic expressions: **whichever side is NOT a bare
literal is checked first**, and its result anchors the other side (if
both are literals, the outer `expected_type` anchors the first, which
then anchors the second) — see chapter 2.1. `CALL`: the callee can only
be a bare `IDENT`, resolved in the global `callable_table` (Stage 0 has
no function pointers/first-class functions); argument count and types
are matched against the signature's params. `FIELD`/`INDEX`: the base's
type must be struct/array, field/index validity is checked.
`STRUCT_LIT`/`ARRAY_LIT`: per-element type propagation, augmented in
Phase 2 with completeness checking (see 7.4/7.5).

### 7.1 Array-literal element count (Phase 2)

In `.array_lit`, when `expected_type` is an actual `AST_TY_ARRAY` (the
practical case — every array-typed position, decl init or struct-field
init, always declares an explicit size): right after determining the
element type, it immediately compares the literal's actual element
count (`AST_EX_ARRAY_LIT`'s own `b` field) against the expected type's
declared size (`AST_TY_ARRAY`'s `b` field, still in `r12` since the
start of the branch). The no-context case (`.array_lit_no_context`)
receives no checking — a rare, defensive branch; in practice a real
program's array literal is never checked this way.

### 7.2 Struct-literal completeness (Phase 2)

A per-field "seen" flag is needed to catch both the **duplicate** case
(a field already seen, given again) and the **missing** case (a field
never seen). No new register is needed: the existing scratch area
(`sub rsp, 32` in `.struct_lit_found`, addressed via the stable `r14`
base) simply grows by `MAX_LIST_ARITY` bytes (`sub rsp, 32 +
MAX_LIST_ARITY`) — one byte per possible field index, directly after
the 4 existing quad slots, addressed as `[r14 + 32 + field_index]`.
Zeroed over `[0, field_count)` as soon as `r13` (the struct decl) is
known — this is stack memory, not `.bss`, so (unlike every other
scratch area in the codebase so far, all of which are `.bss`-based and
thus already zeroed) an explicit zeroing step is required.

`.struct_field_scan`'s loop's own index (`r15`) is exactly the found
field's own index in the struct's field list, by the time
`.struct_field_found` is reached — directly reused as the index into
the "seen" array, no separate bookkeeping needed. There: `[r14+32+r15]`
is checked before anything else — if already `1`, `"duplicate field
initializer 'X'"` is reported at the field_init's own position
(`find_offset`, which has handled `AST_FIELD_INIT` since Phase 1);
otherwise it is set to `1` and processing continues unchanged.

At the end of `.struct_lit_loop` (`.struct_lit_done`, before synthesizing
the return type) it scans `[r14+32, r14+32+field_count)` for any entry
still `0` — `"missing field initializer 'X'"`, naming/positioning it via
that index's own `AST_FIELD_DECL` (from the struct's field list).

### 7.3 Based-form digit range (`validate_int_literal`, Phase 2)

A standalone routine called from `check_expr`'s `.int` branch
(regardless of context, runs before the type is decided). It slices the
literal's raw text back out of `[parser_src_buf + name_offset,
name_len)` (available on `AST_EX_INT` only since Phase 1) and looks for
`'n'`:

- No `'n'` → `decimal_form`, nothing to check.
- `'n'` present → the digits before `'n'` (already guaranteed decimal by
  the lexer) give the base — it must be exactly `2`, `8`, `10`, or `16`
  (four `cmp`s, no table needed for that few values), otherwise
  `"based-form literal base must be 2, 8, 10, or 16, found N"`. Every
  digit after `'n'` is decoded (the same `0-9`/`a-f`/`A-F` folding that
  `lexer.asm`'s `lex_handle_number` uses to compute the value) and
  checked `< base` — the first violation reports `"based-form literal
  has a digit that is not valid in base N"`. Both error branches report
  at the literal's own position (`name_offset` is directly available, no
  need for `find_offset`).

### 7.5 A second bug found and fixed (also via the struct-literal path)

While writing the fixtures for chapter 7.2 above (two field names of
equal length, `struct Point { x; y; }`), a **different**, previously
hidden bug inherited from Phase 1 also surfaced: `.struct_field_scan`
kept the struct's field list and field count in `rcx`/`rdx` for the
entire scan loop, then made a nested `call bytes_equal` — which **itself
also uses `rcx`** as internal scratch, and also overwrites `rdx` (its
3rd argument). At the first comparison where the name length matches
but the actual bytes do not (exactly what happens when searching for
"y" if the first candidate is "x" — both length 1), the loop's own
upper bound got corrupted, and the search prematurely reported "no such
field" — even though the field actually existed, it just hadn't been
reached yet. **Fix:** the struct's field list and field count are
re-read fresh from `r13` (the struct decl, preserved throughout) on
every loop iteration, never cached in `rcx`/`rdx` across the call.

`find_offset(node) -> offset`: since most compound node kinds
(`BINARY`, `UNARY`, `INDEX`, `CALL`, ...) do not carry a position of
their own, this helper recurses into a designated child until it
reaches a node that actually carries a span (`IDENT`/`INT`/`BOOL`/`NULL`/
`FIELD`/`FIELD_INIT`, and `STMT_RETURN` falls back to its own `return`
keyword's position if it has no expression).

### 7.4 A bug found and fixed (Phase 1, surfaced by the large black-box program)

The `.struct_field_found` branch kept the found `AST_FIELD_DECL`
pointer in `rcx`, then, **after** a nested `check_expr` call, re-read
`[rcx + ...]` to fetch the type. `rcx` is a caller-saved register,
clobbered by `check_expr`'s internals — the same class of bug as the
`ast_dump.asm` `emit_str`/`rax` case from the parser phase, just with
`rcx`. Fix: the field type is saved into a preserved register (`r12`,
unused elsewhere on this branch) **before** the nested call.

### 7.6 Compile-time array-index range checking (Phase 3)

In the `.index` branch, after the index expression's `integer`-type
check: this only runs if the index expression is **literally** an
`AST_EX_INT` node (a bare integer literal) — there is no general
constant-folding for arbitrary expressions (e.g. `1+2`), consistent
with the fact that Stage 0 has no optimization/folding pass at all. If
the literal's own value (`AST_A_OFF`) is `>=` the array type's declared
element count (`AST_B_OFF` on the `AST_TY_ARRAY` node), it is a
`"array index out of range for a declared size of N"` error. A genuinely
dynamic (variable/computed) index is **never** checked — this is
intentionally a zero-runtime-cost, compile-time-only diagnostic, not a
hidden runtime bounds check (the code generator's `INDEX` lvalue code
generation never emits a runtime check either, see
`docs/postulate_stage0_codegen_spec.md`).

---

## 8. Statement checking, extern whitelist, `check_program` (`sema_stmt.asm`)

- **`check_decl`**: if there is an initial value, `check_expr` with the
  declared type as the expected type, then `types_equal`.
- **`check_stmt`**: `assign`/`if`/`while`/`return`/`expr_stmt` branches.
  `assign` is the most complex: `lvalue`-shape checking for each pair
  (2.2), `const` checking (2.3), then `check_expr`+`types_equal` for the
  RHS; after all pairs, a pairwise (O(n²), but in practice the pair
  count is 2-4) `lvalue_equal` structural comparison guards against
  duplicate targets — it only checks **syntactic** identity
  (`x := 1, x := 2;` is an error, `arr[i] := 1, arr[j] := 2;` is not,
  even if `i == j` at runtime — no aliasing analysis, a deliberate scope
  limit).
- **`check_extern_whitelist`**: the main spec's chapter 2 fixed set of 4
  signatures (`sys_read`/`sys_write`/`sys_mmap`/`sys_exit`) — name
  identified with `bytes_equal`, then per-parameter `types_equal` against
  expected types synthesized with the `mk_base`/`mk_ptr_base` helpers.
- **`check_program`**: `build_global_tables` (1a) → `resolve_all_types`
  (1b) → every `AST_FUNCTION` body (`build_local_table` +
  `check_func_block`) + every `AST_EXTERN_DECL` against the whitelist
  (pass 2). Struct declarations require no further work — pass 1b has
  already checked their field types.

### 8.1 "Every execution path ends with a return" (Phase 2)

The one item in this phase that isn't "extend an existing branch" —
structural induction over statement *lists*, not checking a single
node's own shape.

- **`stmts_always_return(stmts_ptr, count) -> 1/0`** — true if **any**
  statement in the list always returns (not just the last one: if an
  earlier statement always returns, everything after it is unreachable
  regardless of its own shape — this phase does not introduce a separate
  "unreachable code" warning, it just doesn't let dead code's shape
  influence the decision). Literally shared between `AST_BLOCK` (`a`=stmts,
  `b`=count) and `AST_FUNC_BLOCK` (`c`=stmts, `d`=stmt_count) — same
  node-pointer-array shape, just different field offsets at the two call
  sites.
- **`stmt_always_returns(stmt) -> 1/0`** — dispatcher by kind:
  - `AST_STMT_RETURN` → always `1`.
  - `AST_STMT_IF` → only `1` if **there is** an `else` branch **and**
    both branches (`stmts_always_return` on each) always return. Without
    `else`, always `0` (the no-`else` path falls through by definition).
  - `AST_STMT_WHILE` → generally `0` (Stage 0 has no `break`, but a
    loop body can also run zero times unless the condition is
    necessarily true — this analysis does not reason about arbitrary
    expressions). **One well-founded special case**: if the condition is
    literally the `AST_EX_BOOL` `true` literal, the loop can only exit
    via `return` (or run forever — both are acceptable ways of "never
    falling through this point," the same as e.g. Rust's `loop {}`) —
    this case is `1`, regardless of the body.
  - `AST_STMT_ASSIGN` / `AST_STMT_EXPR` → always `0`.
- **Wiring**: in `check_function_body`, after `check_func_block`
  succeeds, if the function's declared return type is not `void`,
  `stmts_always_return` runs on the func_block's own statement list; if
  `0`, `"function 'X' may not return a value on every execution path"`
  is reported at the function's own name span (from its signature — the
  only diagnostic in this entire phase that anchors on a top-level
  declaration rather than an expression/statement, so it needs no
  `find_offset`, going straight to `err_append_span` on the signature's
  name).

### 8.2 Array broadcast-init (Phase 3)

Both `check_decl`'s and `check_stmt`'s `.assign` pair loop follow the
same `check_expr(rhs, target_type)` + `types_equal` pattern — if that
fails **and** `target_type.kind == AST_TY_ARRAY` **and** `rhs` is not
literally an `AST_EX_ARRAY_LIT` (those already go through their own,
unchanged element-count+element-type check in `check_expr`'s
`.array_lit` branch), a new `check_array_broadcast_compatible` helper
runs as a fallback: it re-checks `rhs` **again**, this time with the
array's **element type** as the expected type (not the array type
itself), and against `types_equal` for the element type. On success this
is a valid broadcast (`mut arr: int32[3] := 0;`), and the existing
`msg_decl_init_type_mismatch`/`msg_assign_type_mismatch` error messages
remain unchanged, only now they only fire for genuine mismatches. The
second `check_expr` call is safe because the routine itself has no side
effects with respect to `expected_type` (only literals consume it, and
they never error on it — the caller's `types_equal` always decides).

---

## 9. Test suite

Three complementary verification layers:

1. **`tests/checker_cases/`** + `scripts/run_checker_tests.sh` — 33
   valid/invalid pairs (66 fixtures: 24 pairs/48 fixtures from Phase 1,
   7 pairs/14 fixtures from Phase 2, 2 pairs/4 fixtures from Phase 3),
   one per rule listed above, each invalid fixture containing **exactly
   one** deviation from its valid counterpart. No directive line (
   `build/checker` always processes the whole file as a single
   `program`).
2. The **12 valid black-box programs** (`tests/blackbox_cases/*_valid.ptl`,
   from the parser phase) rerun through `build/checker` — real,
   non-minimized code to validate the design, not just targeted
   mini-fixtures. In Phase 1 this uncovered the `rcx` bug from chapter
   7.4 and a genuine bug in the project's own test program
   (`sys_exit(common)` called with a `common: int32` argument against an
   `int64` parameter — since the language has no explicit type-conversion
   syntax, this really was invalid; the fixture was fixed, not the
   checker). In Phase 2 all 12 programs passed unchanged, without error,
   through the new completeness/control-flow rules as well.
3. The full `docker build` — all four packages (lexer, white-box parser,
   black-box parser, checker) through a single gate.

Every `.expected.*` comes from the actually-compiled binary's real
output — never hand-guessed.

---

## 10. Items outside Stage 0's scope

These two items are, per the main spec as well, **not** a Stage 0
requirement (not "deferred," but explicitly excluded from this
compiler):

- "Ignored return value" warning — the main spec itself notes it only as
  a future/final compiler feature.
- Forward-declared (bodyless) functions — a separate, not-yet-written
  grammar extension (not the same as `extern function`).

Beyond these, the work that lies outside the semantic analyzer and
requires its own phase: **code generation** (LLVM IR or native code) —
the next, substantively different step in the bootstrap chain.
