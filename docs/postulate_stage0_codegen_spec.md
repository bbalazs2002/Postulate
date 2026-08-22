# Postulate Stage 0 — Code Generator Technical Specification

> This document is the technical specification of the Stage 0 bootstrap
> compiler's **code generator** — **Phase 1**: single-function (`main`),
> scalar-types-only, full expression/`if`/`while` code generation, up to
> and including calls to the whitelisted `extern` syscalls. **Phase 2**:
> struct/array/pointer-typed locals and parameters, full
> `INDEX`/`FIELD`/`UNARY(*)`/`UNARY(&)` code generation, struct/array
> literals (`STRUCT_LIT`/`ARRAY_LIT`), array broadcast-init, simple
> struct/array value copying (`p2 := p1;`), and calls among an arbitrary
> number of user functions (including recursion) — **excluding**, out of
> all of this, the transfer of a struct/array **value** across a
> function-call boundary (as an argument or as a return value).
> **Phase 3**: exactly this omitted item — a struct/array value can now
> cross a call boundary both as an argument **and** as a return value
> (see Chapters 2 and 6.5-6.8); two narrow, deliberately deferred cases
> remain open (see Chapter 10). The goal is a **fourth, standalone
> `build/codegen` binary** — continuing the `lexer → parser → checker →
> codegen` layering. Its prerequisites are
> [postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
> (the already-completed, full semantic check — the generated code is
> only produced for a program that has already passed it) and
> [postulate_stage0_parser_spec.md](postulate_stage0_parser_spec.md)
> (AST node layout). The Stage 0 compiler's final name is **Hoare**;
> this pass is not yet the unified `hoare` CLI, but one of its
> intermediate building blocks.
>
> Reminder (2026-08-21 decision): **Stage 0 has no optimizing pass** —
> the code generation below is deliberately naive (no register
> allocation, constant folding, or dead-code elimination). Optimization
> will be the job of the Stage 1 compiler (self-hosting, written in
> Postulate).

---

## 1. Goal and Scope

- **Output**: `build/codegen` writes **NASM assembly text** to stdout,
  which the already-existing `nasm`+`ld` toolchain compiles and links
  (the same chain that `Hoare/scripts/build.sh` itself uses) — there is
  no custom ELF writer or linker.
- **Struct layout**: **packed, no padding** — fields laid out one after
  another in declaration order, with no filler. This is worth
  revisiting when Stage 1 is written (natural/ABI alignment will likely
  be the alternative then); for now it is the simplest correct choice
  for a non-optimizing bootstrap compiler.
- **Phase 1 scope** — the simplest end-to-end slice that proves out the
  whole new pipeline (`.ptl` → checked AST → `.asm` text → `nasm`+`ld` →
  real Linux binary → **run and verified**) before the complexity of
  memory layout is added: a single function (`main`), scalar types
  only, full expression/`if`/`while` code generation, calls only to
  whitelisted `extern` functions.
- **Phase 2 scope** (see Chapter 6 for details) — everything Phase 1
  marked as "documented, deferred", except for transferring a
  struct/array **value** across a call boundary:
  - Struct/array/pointer-typed `decl`/parameter (in Phase 2, parameters
    remained **only** scalar/pointer, because a parameter by definition
    crosses a call boundary, while a `decl` does not — Phase 3 resolves
    this, see below).
  - `INDEX`/`FIELD`/`UNARY(*)`/`UNARY(&)` — chainable to arbitrary
    depth (`*arr[2]`, `*values.value.ptrs[3]`), via a recursive
    `gen_lvalue`/`gen_rvalue` definition.
  - `STRUCT_LIT`/`ARRAY_LIT` (in decl-init, and on the right-hand side
    of both single-pair and multi-pair simultaneous assignment), array
    broadcast-init, simple struct/array value copying (`p2 := p1;`).
  - An arbitrary number of `AST_FUNCTION`s, calling each other,
    including recursion.
  - `sys_read`/`sys_write`/`sys_mmap` can now actually be called (code
    generation now exists for their pointer arguments).
- **Phase 3 scope** (see Chapter 2 and 6.5-6.8 for details) — a
  struct/array **value** can now cross a user function-call boundary in
  both directions:
  - **As an argument**: an incoming 8-byte slot of a composite
    parameter now holds an **address** instead of a value (the same way
    a pointer argument already did) — the caller either passes the
    address of an already-existing lvalue (local, field, element, or
    the result of another composite-returning call) directly,
    **without copying**, or (for a struct/array literal argument)
    materializes it into a fresh temporary area. The **actual**,
    by-value copy is made by the **callee's own** prologue
    (`emit_param_copy`'s composite branch, `rep movsb` from the
    incoming pointer into its own local slot) — so nothing needs to be
    "protected" on the caller's side after the call; the callee gets
    its own, independent instance.
  - **As a return value**: the hidden `rdx` output-pointer convention
    (see Chapter 2, documented since Phase 2, now wired up) — the
    caller allocates a fresh temporary area on the target program's own
    stack (`sub rsp, <size>`), passes its address in `rdx`, and the
    callee writes the value returned by `return` there directly,
    instead of into `rax`.
  - Every other construct (see Chapter 10: a composite-returning call
    as a struct/array literal field/element value; composite-typed
    `BINARY` operators) **is documented below**, but **not
    implemented** — these are cleanly flagged by the
    `codegen error: ...` diagnostic (exit code 4, see Chapter 9),
    instead of generating incorrect code.

---

## 2. Calling Convention

**Not the platform ABI — a custom, uniform, argument-count-independent
convention** for user-function calls (`extern`/syscall calls are a
separate, fixed-shape path, see Chapter 6, `AST_EX_CALL` — this
decision never needs to interoperate with the real SysV ABI, because
there is no foreign code that a compiled Postulate function would need
to make directly callable *from itself* — `extern function` is a
closed, 4-syscall whitelist, not a general FFI).

- Arguments are evaluated **right to left**, and are **push**ed
  immediately, one at a time — regardless of their count. Since `arg1`
  (the leftmost) is evaluated **last**, it is also pushed last, so it
  ends up closest to `rsp` on the stack — the stack is readable
  top-to-bottom in `arg1, arg2, ..., argN` order, in 8-byte slots each
  (uniformly 8 bytes, regardless of the argument's actual declared size
  — the simplest addressing: `[block_ptr + (i-1)*8]`). A
  **scalar/pointer** argument's slot holds its value; a **composite**
  argument's slot (Phase 3) holds an **address** (see below) — so the
  slot size and the shape of the convention do not change, only what
  the 8 bytes inside it mean.
- The callee receives exactly **two** things, in **`rdi`**/**`rsi`**: a
  pointer to the first argument (`rdi`) and the argument count (`rsi`)
  — always these same two registers, regardless of the actual argument
  count.
- **Return value**: scalar/pointer types → `rax` (unchanged). `void` →
  `rax` unused. **Struct/array return types** (Phase 3): the caller
  passes a third, hidden argument — a pointer to where the result must
  be written (`rdx`, which this convention otherwise does not use) —
  and the callee writes the result through this pointer, instead of
  into `rax`. The caller does **not** keep this pointer alive in a
  register for the whole duration of argument evaluation (nested calls
  would freely clobber it) — instead it allocates the target area
  **ahead of** its own argument block (`sub rsp, <size, rounded up to
  8>`, `gen_lvalue`'s `CALL` branch, `codegen_expr.asm`), then,
  immediately before `call pf_<name>`, recomputes its address with a
  compile-time-known `lea rdx, [rsp + N]` (`N` = the total,
  by-then-known size of the call's own argument block, see below) — it
  needs no extra register at all to "survive" the intervening
  evaluation.
- **Composite argument materialization** (Phase 3, `gen_user_call`,
  `codegen_expr.asm`): whether an argument is composite is decided by
  the callee's own parameter type (not the argument expression's own,
  possibly different type — though the checker already guarantees the
  two match). If it is:
  - **lvalue-shaped source** (`IDENT`/`INDEX`/`FIELD`/`UNARY(*)`/`CALL`):
    the source's **own** address (`gen_lvalue(arg) -> rbx`) is pushed
    directly, **without copying** — the callee's own prologue
    (`emit_param_copy`) copies out its own, independent instance from
    there, so there is no point copying in advance on the caller's
    side.
  - **struct/array literal source**: a fresh temporary area is
    allocated (`sub rsp, <size, rounded up to 8>`), the literal is
    materialized into it (`gen_init_push`/`gen_init_pop_store`, see 6.6
    — the destination address is computed back from `gen_init_push`'s
    **return value** [total bytes pushed], with a compile-time-known
    `lea rbx, [rsp + leaf_bytes]`, because the leaves are pushed
    **after** the allocation), and then the address of this fresh area
    is pushed.
  - All such temporary areas (both for composite arguments and for an
    argument coming from a nested, composite-returning call) are freed
    by the call's **own** final `add rsp, N` — from this point on `N`
    is not simply `arg_count*8`, but the sum of every argument's
    actually allocated size, rounded up to 16 (the padding decision
    therefore needs a preliminary, nothing-emitting pass that computes
    `N` before emitting anything — see `gen_user_call`'s header).
- The caller cleans up after the call (`add rsp, N`, with `N` known at
  compile time per call site — rounded up to 16 beforehand, see
  Chapter 4 and above).

**Stipulation, stated explicitly**: argument expressions are evaluated
**right to left**. If the evaluation of two arguments touches shared
state (through side-effecting nested calls, pointers derived from `&`,
etc.), the right-hand argument's side effect happens first. This is
**intentional, documented** behavior, not a bug. It applies equally to
`extern`/syscall call sites (see Chapter 6) — so the whole language has
**exactly one** evaluation-order rule, even though the two kinds of
calls place the evaluated arguments differently.

### 2.1 Stack Discipline

**Every `push` that a function's generated code emits must have a
matching `pop`** (or an equivalent bulk `add rsp, ...`) before the
function returns. A function's own net effect on `rsp`, from the end of
the prologue to the start of the epilogue, must be **zero**.

This matters especially because of the calling convention above: a
callee receives a pointer (`rdi`) into memory that it did **not** push
itself — the caller's freshly pushed argument block, located *above*
the callee's own `rbp` in the caller's frame. A function may freely
**read** stack memory it did not push (its own incoming argument block
is exactly this), but it must never `pop` it, write into it, or treat
it as its own local scratch area — only whoever pushed a given area may
reclaim it.

---

## 3. Register Convention: Value vs. Address

Every expression code-generation routine is one of two kinds, each with
its **own, separate result register** — strictly kept apart, so that
they don't both go through `rax`, so that a construct that needs both a
value **and** an address at once (simultaneous assignment is the
motivating case) never silently overwrites the other:

- **`gen_rvalue(node) -> value in the target `rax``** — "what does this
  expression evaluate to". Signed types are sign-extended to 64 bits
  with `movsx`, unsigned/`bool` with `movzx`.
- **`gen_lvalue(node) -> address in the target `rbx``** — "where does
  this expression live in memory". Used only for the target of an
  assignment and the operand of `&` — and chained, since `gen_rvalue`
  itself calls this for `IDENT`/`INDEX`/`FIELD`/`UNARY(*)`.

`rbx` is callee-saved, so it survives any nested `call`/`syscall`
without extra protection, and the codebase has already assigned it this
role elsewhere (e.g. `sema_expr.asm`'s `.struct_lit` scratch base).

**Note on the "two worlds"**: this document (and the corresponding
`codegen_*.asm` files) use `rbx`/`r12`-`r15` for **the Stage 0
compiler's own** compile-time bookkeeping, following the codebase's
universal convention — this is entirely separate from the `rbx`
discussed above, which refers to a runtime register of the
**generated** assembly text, read back only by code that explicitly
emits the text `"[rbx]"` (`emit_sized_load`/`emit_sized_store`).

---

## 4. Stack Frame Layout

Classic frame-pointer prologue/epilogue:

```nasm
pf_main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, <locals_size>     ; rounded up to a multiple of 16
    ; -- one load+store per parameter, from [rdi + i*8] --
    ; ... body ...
.epilogue:
    mov     rsp, rbp
    pop     rbp
    ret
```

`<locals_size>` must be a multiple of 16: the ABI guarantees that
`rsp % 16 == 0` immediately before a `call`; the `call` itself pushes an
8-byte return address (on callee entry: `rsp % 16 == 8`); `push rbp`
restores 16-alignment (`rsp % 16 == 0`) — so `sub rsp, N` preserves this
invariant (which *this* function's own nested `call`s need) only if
`N % 16 == 0`.

Every local (parameter or `decl`) gets exactly **one fixed stack slot**,
sized according to its own type. Parameters arrive as a pointer+count
pair (see Chapter 2), and are copied immediately into their own slot in
the prologue.

**Reuse**: the per-function local list already exists from the semantic
checker (`symtab.asm`'s `build_local_table`/`local_table`) — the code
generator does not re-derive it, but reruns it (`build_local_table`,
already exported), and adds a **parallel array**
(`codegen_program.asm`'s `local_offsets`), indexed the same way as
`local_table` — not a `symtab.inc` modification.

**Debug-only instrumentation** (`POSTULATE_STACK_CHECK=1`, see Chapter
11): when set, every local's offset shifts down by 8 bytes to make room
for a stack canary at `[rbp - 8]` — `compute_local_offsets`'s running
total starts at 8 instead of 0, so this is transparent to every consumer
of `local_offsets`/`local_stack_offset` (param copies, lvalue lookups,
decl inits). With the env var unset, offsets are exactly as shown above.

---

## 5. Type Sizes and Struct Layout (`codegen_types.asm`)

| Type | Size | Signed? |
|---|---|---|
| `int8` / `uint8` / `bool` | 1 byte | yes / no / n/a |
| `int16` / `uint16` / `int` / `uint` | 2 bytes | yes / no |
| `int32` / `uint32` | 4 bytes | yes / no |
| `int64` / `uint64` | 8 bytes | yes / no |
| pointer (any `AST_TY_POINTER`) | 8 bytes | n/a (address) |
| array `T[N]` | `size(T) * N`, contiguous | n/a |
| struct | packed sum of field sizes, in declaration order | n/a |

`type_size(type_node) -> bytes`, `is_signed_type(type_node) -> 1/0`,
`struct_size(struct_decl) -> bytes`, `field_offset(struct_decl, name) ->
bytes`, `field_type(struct_decl, name) -> type` (the latter two via a
linear search by field name, the same shape, just a different return
value — see `sema_expr.asm`'s `.struct_field_scan` pattern, not shared
code).

`is_scalar_loadable_type(type_node) -> 1/0` — true if the type actually
fits into an 8-byte register (a built-in base type or a pointer).
`decl`s accept **any** type (locals never cross a call boundary on
their own), but the code generator runs this narrower check at a number
of points, now for a **decision**, not for a **rejection** (since
Phase 3 — in Phase 2 these same points still reacted to a `false`
result exclusively with `codegen_fail`):

- `gen_rvalue`'s `IDENT`/`INDEX`/`FIELD`/`UNARY(*)` load path, before
  putting the loaded value into `rax` — a `false` here is still
  `codegen_fail` (`msg_composite_as_scalar`): a composite value can
  never be treated directly as a scalar, only through its
  fields/elements, or via a full copy.
- `gen_rvalue`'s `BINARY` branch (only for the left operand — the right
  side is guaranteed to be the same type, see `types_equal`) —
  rejected the same way (see Chapter 10: this is a deliberately-not-
  closed permissive gap in the checker, not the subject of Phase 3).
- `gen_rvalue`'s `CALL` branch: before taking the called function's
  return value into `rax`, it checks whether it is scalar — if not,
  `codegen_fail`, because `gen_rvalue` may never return a composite
  value (see 6.5 below). A composite-returning call is reachable
  **only** through `gen_lvalue`'s own `CALL` branch.
- `gen_function` decides based on the parameter/return type (see 6.8):
  scalar → the old, unchanged copy/return path; composite → the new,
  Phase-3 path (`emit_param_copy`'s composite branch, and the hidden
  output-pointer slot). **There is no longer a rejection** at this
  point.
- `gen_user_call` likewise decides based on the callee's declared
  return type and each individual parameter (scalar or composite
  branch), rejecting nothing — see 6.5.

---

## 6. AST Node → Assembly, with Implementation Status

### 6.1 Literals, Identifier (implemented)

`AST_EX_INT`/`AST_EX_BOOL`: `mov rax, <value>`. `AST_EX_NULL`:
`mov rax, 0` (in practice unreachable in a well-typed, scalar-only
program, since without a pointer context it could never appear in a
valid program — pointers do not exist in this phase). `AST_EX_IDENT`:
`gen_lvalue` (`lea rbx, [rbp - offset]`), then `emit_sized_load`.

### 6.2 Unary (implemented: all)

| op | code generation |
|---|---|
| `-` | `gen_rvalue(operand)`; `neg rax` |
| `!` | `gen_rvalue(operand)`; `xor rax, 1` |
| `*` (deref) | rvalue: `gen_lvalue` (the pointer's value *is itself* the target address: `gen_rvalue(operand) -> rax`; `mov rbx, rax`), then guarded `emit_sized_load` — the same path as `IDENT`/`INDEX`/`FIELD` |
| `&` (address-of) | rvalue only: `gen_lvalue(operand) -> rbx`; `mov rax, rbx`; the result type is a freshly synthesized `AST_TY_POINTER` (`ast_alloc_node`, the same pattern as `sema_expr.asm`'s `.unary_addr`) |

### 6.3 Binary (implemented: all)

General pattern (except for `&&`/`||`):

```nasm
    ; gen_rvalue(left)
    push    rax
    ; gen_rvalue(right)
    mov     rcx, rax        ; rcx = right
    pop     rax             ; rax = left
    ; combine (op-specific) -- result in rax
```

| Ops | Combining step |
|---|---|
| `+ - * & \| ^` | `add/sub/imul/and/or/xor rax, rcx` |
| `<< >>` | `shl rax, cl` always; `>>`: `sar` (signed) / `shr` (unsigned) |
| `/ %` | `cqo`+`idiv rcx` (signed) or `xor rdx,rdx`+`div rcx` (unsigned); `%` moves `rdx` into `rax` |
| `== != < > <= >=` | `cmp rax, rcx` + `setcc al` (`==`/`!=` sign-independent; `< > <= >=` `setl/setg/setle/setge` signed, `setb/seta/setbe/setae` unsigned) + `movzx rax, al` |
| `&& \|\|` | short-circuit, with unique `.L<N>_false`/`.L<N>_true`/`.L<N>_end` labels — see below |

```nasm
; a && b
    ; gen_rvalue(a)
    cmp     rax, 0
    je      .L<N>_false
    ; gen_rvalue(b)
    jmp     .L<N>_end
.L<N>_false:
    mov     rax, 0
.L<N>_end:
```

### 6.4 `INDEX` / `FIELD` (implemented)

Lvalue: `gen_lvalue(base) -> rbx`; `INDEX`: `push rbx; gen_rvalue(index);
imul rax, elem_size; pop rbx; add rbx, rax`. `FIELD`: `gen_lvalue(base)`
(always struct-typed), `add rbx, field_offset(struct_decl, name)`. Both
can be chained to arbitrary depth with other lvalue shapes (`*arr[2]`,
`*values.value.ptrs[3]`), since `gen_lvalue`/`gen_rvalue` are defined
recursively over the whole expression grammar, not by shape-based
pattern matching — the depth is "free". There is no runtime `INDEX`
bounds check (in keeping with the "no hidden runtime cost" principle) —
a compile-time range check, limited to bare-literal indices, in the
semantic analyzer already filters out constant-index out-of-bounds
addressing beforehand (see
[postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
§7.6); a genuinely dynamic index is never checked.

### 6.5 `CALL` (implemented: `extern` whitelist and user functions, with arbitrary argument/return types)

```nasm
    ; argN..arg1, right to left, pushed one at a time
.push_loop:
    ; gen_rvalue(arg_i); push rax
    ; -- extern (syscall) case --
    pop     rdi                 ; if arg_count >= 1
    pop     rsi                 ; if >= 2
    pop     rdx                 ; if >= 3
    pop     rcx                 ; if >= 4
    mov     r10, rcx            ; syscall clobbers rcx/r11, hence r10
    pop     r8                  ; if >= 5
    pop     r9                  ; if >= 6
    mov     rax, <syscall number>
    syscall
```

The syscall numbers (`sys_read`=0, `sys_write`=1, `sys_mmap`=9,
`sys_exit`=60) are the same ones `runtime.asm` already uses,
cross-checked, not reinvented.

In Phase 1, `sys_read`/`sys_write`/`sys_mmap` each required at least one
`*uint8` (pointer) parameter, which was not yet code-generated at the
time — from Phase 2 onward all three can actually be called
(`21_sys_write_real_buffer` fixture: a real buffer, `&msg[0]`).

**User function call** (`gen_user_call`, `codegen_expr.asm`) — exactly
the convention described above: evaluated and pushed right to left (a
dummy padding push **first**, if needed — see Chapter 2 on the Phase-3
generalization of the padding decision); `mov rdi, rsp; mov rsi, N;
[lea rdx, [rsp + N'], if the return type is composite]; call pf_<name>;
add rsp, <N', rounded up to 16>`. Every argument resolves to the
scalar/composite branch based on the callee's **own, declared**
parameter type (not the argument expression's own type):

- **scalar/pointer**: unchanged, `gen_rvalue(arg) -> rax`; `push rax`.
- **composite**: see Chapter 2 ("Composite argument materialization")
  — either the source's **own** address is pushed (lvalue shape), or a
  fresh temporary area is materialized and its address is pushed
  (literal shape).

The callee's own return type is likewise resolved based on its
declared type (`gen_user_call`, immediately before `call`): `void`/
scalar → unchanged; composite → the hidden `rdx` output pointer wired
up (see Chapter 2). Recursion (direct or mutual) needs nothing extra:
every call gets a frame at its own fresh `rsp`, and
`local_table`/`local_offsets` are used only *at generation time*
(compile time), never at runtime — this holds equally for a function
recursing with a composite parameter/return type (see `codegen_cases/
27_composite_recursion.ptl`).

**Why `BINARY` needs no separate guard**: `gen_rvalue` itself **never**
returns a composite (struct/array) type — `.load_via_lvalue`/`.deref`
guard themselves (`is_scalar_loadable_type`), `INT`/`BOOL`/`NULL`/
`neg`/`lnot`/`addr` are always scalar/pointer by their own rules, and
`.call` already guarded the callee's return type before returning (see
Chapter 5) — a composite-returning call is reachable only through
`gen_lvalue`, never through `gen_rvalue`. This invariant is inherited
by induction: nothing that passes through `gen_rvalue` can ever be
composite-typed, so `BINARY`'s operands (both sides evaluated through
`gen_rvalue`) can never be either.

**`gen_lvalue`'s own `CALL` branch** (Phase 3, `codegen_expr.asm`) —
the only path through which a composite-returning call is reachable: it
allocates a fresh area sized to the callee's return type (`sub rsp,
<size, rounded up to 8>` — this area already exists before
`gen_user_call` even starts evaluating the arguments, so their
placement on the stack is *below* it and never disturbs it), calls
`gen_user_call` (so the hidden `rdx` receives this area), then returns
this area's address as its own result (target `rbx`). It **deliberately
does not free** this area — the caller (whoever that may be:
decl-init/assign copy, reading out a scalar field/element, or
materializing a nested composite argument) is handed this
responsibility via a third output value returned from `gen_lvalue`
(`r8`, in the compiler's own register, the "cleanup size"): `0` if
there is nothing to free (the address of an existing local), or the
allocated byte count if there is — the `INDEX`/`FIELD` branches pass
this through unchanged if their own base address likewise originates
from such a call (`f().field`, `f()[i]`). Without this mechanism, a
repeatedly called, composite-returning function (e.g. in a loop, or
used multiple times in an expression) would leak stack space without
bound, all the way to the function's epilogue — this was a real risk
discovered during design, and closed off by the `r8`/cleanup mechanism.

### 6.6 `STRUCT_LIT` / `ARRAY_LIT` (implemented) + array broadcast-init + struct/array copying

New file: `codegen_composite.asm`. A third code-generation mode, used
**uniformly** in decl-init, and on the right-hand side of both
single-pair and multi-pair simultaneous assignment (no separate fast
path) — two functions, always called together:

- **`gen_init_push(node)`** (pass 1): walks the literal **forward**, in
  declaration/index order; for every **leaf** (scalar/pointer)
  field/element: `gen_rvalue(leaf) -> rax`; `push rax`. A nested
  composite field/element joins the same flat, forward-order push
  sequence via inline recursion — **no address whatsoever** surfaces in
  this pass, it is purely value computation, so every leaf really does
  see the *pre-statement* state, regardless of which pair or position
  it is part of.
- The destination address is computed and pushed **last**, **after**
  `gen_init_push` returns (`gen_lvalue(lhs) -> rbx`; `push rbx`) — safe,
  because nothing after this touches `rbx` for this pair, and the fact
  that it is computed *afterward* (rather than earlier, as in the
  scalar case) does not change what pre-state it sees, since nothing
  *writes* yet in this pass.
- **`gen_init_pop_store(node, expected_type, offset)`** (pass 2, when
  this pair's turn comes in the pairs' own reversed order): first
  `pop rbx` (the address that was pushed last in pass 1, so it is on
  top); then, walking the same structure in **reverse** order, `offset`
  accumulates as compile-time arithmetic through the nested recursion
  (no separate stack entry per level — everything is addressed off the
  retained `rbx`); for every leaf (walked in reverse, matching LIFO pop
  order): `pop rax`; store with a new
  `emit_sized_store_rbx_plus(type, offset)` (the same as
  `emit_sized_store`, just with `"[rbx + <offset>]"` instead of
  `"[rbx]"` — because a single retained base address serves many
  differently-offset stores within one literal).
- Field-name → declared-field mapping (which `field_init` corresponds
  to which struct field, and in what order they must be pushed/popped)
  via a new `find_field_init` helper — the same shape as
  `sema_expr.asm`'s `.struct_field_scan`, not shared code.

**Simple struct/array value copying** (`p2 := p1;`, checked against the
checker — a struct-typed `IDENT` is a perfectly valid right-hand side
for a target of the same type, per the same structural `types_equal`):
a straight `rep movsb` memory copy (`emit_rep_movsb_copy`,
`rdi`=destination, `rsi`=source, already set up by the caller, `cld` to
clear the direction flag).

**Array broadcast-init** (`mut arr: int32[5] := 7;` — made possible by
a new rule in the semantic analyzer's Phase 3, see
[postulate_stage0_semantics_spec.md](postulate_stage0_semantics_spec.md)
§A1/§8.2): the scalar expression is evaluated **once** (`gen_rvalue ->
rax`), then a runtime, counted loop (`gen_composite_broadcast`) stores
that same one value into all `N` element slots (`elem_type`-sized
`mov [rbx], r12<b/w/d/->` + `add rbx, elem_size` + `dec rcx` loop, with
unique `.L<N>_start`/`.L<N>_end` labels). A **composite** broadcast
source (when the element type is itself a struct/array) is deliberately
rejected with `codegen_fail` — a rare case, not implemented in this
phase.

### 6.7 Statements (implemented: all)

- **`AST_DECL_MUT`/`CONST`**: without an init, nothing is emitted. With
  an init, it branches four ways based on the declared type and the
  shape of the init expression:
  - **scalar/pointer** (`is_scalar_loadable_type`): `gen_rvalue` then
    `gen_named_local_addr` then `emit_sized_store` — safe in this
    order, because computing a simple local's address never touches
    `rax` (unchanged since Phase 1).
  - **composite, init is a `STRUCT_LIT`/`ARRAY_LIT`**: `gen_init_push`
    then `gen_named_local_addr` then `gen_init_pop_store` (see 6.6) —
    a single write, no simultaneity risk, so the push/pop protection of
    the address is not needed here (unlike multi-pair `ASSIGN` below).
  - **composite, init is an lvalue of the same type** (`IDENT`/`INDEX`/
    `FIELD`/`UNARY(*)`/`CALL` — the latter since Phase 3, see 6.5, with
    `gen_lvalue`+`types_equal` matching against the declared type):
    struct/array copy (see 6.6); if the source was a `CALL`,
    `gen_lvalue`'s own `r8` (cleanup) output is freed **after** the
    copy (`add rsp, r8`, if nonzero — see 6.5).
  - **composite, init is anything else** (guaranteed scalar/pointer,
    see the induction argument in 6.5): array broadcast-init (see 6.6)
    — valid only if the declared type is an array (the checker never
    allows struct broadcast).
- **`AST_STMT_ASSIGN`**: Dijkstra/Hoare simultaneous semantics, in
  **two passes**, **per pair, in one of four shapes** (scalar,
  composite literal, composite copy, array broadcast — the same four
  cases as above, just adapted to the two-pass push/pop scheme). Each
  pair's own (shape, type) pair is stored in a 2-qword-per-pair scratch
  array on the Stage 0 compiler's **own native** stack — entirely
  separate from the "push"/"pop" **text** that this routine emits into
  the *target* program's stack:
  - **scalar**: pass 1: `gen_lvalue(lhs)` (push address),
    `gen_rvalue(rhs)` (push value) — address **first**. Pass 2: pop
    value, pop address, store.
  - **composite literal**: pass 1: `gen_init_push(rhs)` (leaves pushed,
    in forward order), **then** `gen_lvalue(lhs)` (address pushed
    **last**) — reversed order compared to the scalar case, see the
    detailed reasoning in 6.6. Pass 2: pop address,
    `gen_init_pop_store`.
  - **composite copy**: pass 1: `gen_lvalue(lhs)` (push destination
    address), `gen_lvalue(rhs)` (push source address; source shape
    `IDENT`/`INDEX`/`FIELD`/`UNARY(*)`/`CALL` — the latter since
    Phase 3) — both are pure reads, order-independent. Pass 2: pop
    source → `rsi`, pop destination → `rdi`, `emit_rep_movsb_copy`,
    then, if the source's `gen_lvalue` returned a nonzero `r8`
    (cleanup) output, free it (`add rsp, r8`) — because of this, the
    pair's own scratch entry is 3 qwords/pair since Phase 3 (shape,
    left-hand type, cleanup), not 2.
  - **array broadcast**: the same push shape as the scalar case
    (address, value), but in pass 2 `gen_composite_broadcast` is used
    instead of plain `emit_sized_store`.
  
  The decision among the four shapes (per pair) is purely structural —
  it looks at the left-hand declared type and the right-hand AST shape,
  requiring no evaluation/emission, so the decision is also
  reproducible in pass 2 (where it must again "know" which shape it
  was, without evaluation) without re-emitting anything.
- **`AST_STMT_IF`/`AST_STMT_WHILE`**: with unique `.L<N>_else`/
  `.L<N>_end` and `.L<N>_start`/`.L<N>_end` labels respectively,
  controlled by `cmp rax, 0`+`je`.
- **`AST_STMT_RETURN`**: decided by the enclosing function's declared
  return type (`cur_func_return_type`/`cur_func_out_ptr_offset`, two
  module-level globals that `gen_function` sets once before the body's
  code generation begins — see 6.8; not threaded through
  `gen_func_block`/`gen_block`/`gen_stmt` as a parameter, because
  `gen_function` is never reentrant, so exactly one valid value is ever
  alive at a time):
  - **scalar/`void`**: unchanged — with an expression, `gen_rvalue`
    (the value in `rax`, the ABI return register), `jmp .epilogue`;
    without an expression, `jmp .epilogue` directly.
  - **composite** (Phase 3): the destination address is loaded from the
    hidden slot saved by the caller (`[rbp - cur_func_out_ptr_offset]`,
    see 6.8), and the value is written there directly — for a
    struct/array literal, `gen_init_push`/`gen_init_pop_store` (see
    6.6, the destination address is computed **after** the leaves are
    pushed, the same as for decl-init/assign); otherwise (lvalue shape,
    including `CALL`) `gen_lvalue(expr) -> rbx` + `emit_rep_movsb_copy`.
    Any `r8` (cleanup) output from the source is **deliberately not
    freed** here — the `.epilogue` (`mov rsp, rbp`) that follows
    immediately after discards the whole frame anyway, cleanup or not.
  Every function has exactly one epilogue label.
- **`AST_STMT_EXPR`**: `gen_rvalue`, the result discarded.

### 6.8 Top Level (implemented: `AST_FUNCTION`+`AST_PROGRAM`; `AST_EXTERN_DECL`/`AST_STRUCT_DECL` emit nothing)

- **`AST_FUNCTION`**: a `pf_<name>` label (assembled dynamically from
  the function's own name, not just hardcoded for `main`). Since
  Phase 3 the return type **and** every parameter's type may be
  arbitrary (there is no longer a case rejected with `codegen_fail`
  here):
  - **scalar/pointer parameter**: an unchanged sized-load+store copy
    from the incoming slot (`emit_param_copy`'s scalar branch).
  - **composite parameter**: the incoming slot holds a **pointer** —
    `emit_param_copy`'s composite branch copies, with `rep movsb`, from
    the pointed-to memory into its own local slot (the incoming
    argument block's own base address, target `rdi`, temporarily
    saved/restored with a `push`/`pop` pair while `rdi`/`rsi` play the
    role of `rep movsb`'s destination/source).
  - **`void`/scalar return type**: unchanged.
  - **composite return type**: the prologue allocates one extra,
    always 8-byte, hidden slot (immediately after the size of the
    visible locals, so the total `sub rsp, ...` size is again rounded
    up to 16), and saves the incoming `rdx` there (the caller's output
    pointer, see Chapter 2) — right after the prologue, before the body
    can do anything else with it. This slot's address
    (`cur_func_out_ptr_offset`) and the declared return type
    (`cur_func_return_type`) are passed to `gen_stmt`'s `.return_stmt`
    branch (see 6.7) via two module-level globals — **not** as part of
    `local_table`/`compute_local_offsets` (which remains purely for
    user-declared locals/parameters).
  Prologue sized from its own local table; body via `gen_func_block`;
  one epilogue. An arbitrary number of `AST_FUNCTION`s is allowed,
  generated **in declaration order** (label references among them are
  resolved at compile time, at the NASM level, independent of emission
  order — mutual recursion therefore needs no special handling).
  Exactly one of them must be named `main` (the `_start` entry point
  calls it) — if there is none, `codegen error`. `main` must have
  **zero** parameters (`_start` never sets up `rdi`/`rsi` before
  `call pf_main`) — `gen_program` checks this explicitly, with a
  `codegen error` if violated.
- **Entry point / `AST_PROGRAM`**:

```nasm
BITS 64
section .text
global _start

_start:
    call    pf_main
    mov     rdi, rax        ; main's return value -> exit code
                             ; (mov rdi, 0, if main : void)
    mov     rax, 60         ; sys_exit
    syscall

pf_main:
    ...
```

---

## 7. New Binary: `build/codegen`

The fourth pass, with the same layering discipline as
`lexer → parser → checker`: the entire existing lexer/parser stack
(unchanged), plus the semantic checker's `symtab.asm`/`sema_types.asm`
(reused directly — for `build_global_tables`/`build_local_table`/type
resolution), but **not** the *checking* logic of `sema_expr.asm`/
`sema_stmt.asm` (the code generator only wants the tables built by
`check_program`, not its yes/no verdict — `parse_program` +
`check_program` are rerun following `build/checker`'s pattern, then
`gen_program`).

**Phase-scope enforcement** (from Phase 2 onward): there is no longer
an exact "single function" restriction — both `AST_STRUCT_DECL` and
`AST_EXTERN_DECL` are silently left out of code generation (not an
error), and an arbitrary number of `AST_FUNCTION`s is allowed. The only
thing enforced: exactly one zero-parameter function named `main` must
be present (`gen_program`). Since Phase 3 there is **no** longer any
restriction on a function's return type/parameters (see 6.8) — the
`codegen_fail` surface is limited to the two, much narrower cases
described in Chapter 10.

Files: `codegen_types.asm`, `codegen_expr.asm`, `codegen_stmt.asm`,
`codegen_program.asm`, `codegen_composite.asm` (from Phase 2, see 6.6),
`codegen_main.asm`.

---

## 8. Testing — a New Kind of Verification

Every previous pass's fixtures compared **static text**. The code
generator's fixtures must prove something stronger: that the
**generated assembly, compiled, linked, and actually run, behaves
correctly**. `Hoare/scripts/run_codegen_tests.sh`: for every
`tests/codegen_cases/*.ptl`, `build/codegen` → `.asm` text →
`nasm -f elf64` → `ld -static -no-pie` → **running the resulting
binary** → comparing the real exit code (and stdout, if there is an
`.expected.stdout`) against the packaged `.expected.exit`/
`.expected.stdout` pair.

The 29 fixtures under `tests/codegen_cases/` (10 from Phase 1, 12 from
Phase 2, 7 from Phase 3) cover: arithmetic, comparisons (signed and
unsigned), `if`/`else`, `while`, `&&`/`||` short-circuiting
(observably — a division by zero that would only run if evaluated
incorrectly), an explicit `sys_exit` call, unary/bitwise operators,
division/remainder, simultaneous assignment, struct field read/write,
array index read/write, pointer write through a dereference,
struct/array literal decl-init (including a nested array-struct-array
literal), struct value copying, **a multi-pair simultaneous assignment
in which a struct-literal pair's field expression reads a variable
modified by another pair in the SAME statement** (the most important
Phase-2 correctness test — only correct if the literal's field really
did see the *pre-statement* value), a two-function program, recursion
(factorial), a real `sys_write` with an actual buffer, array
broadcast-init.

**Phase 3's fixtures**: a struct argument passed by value (the callee
modifies its own copy, and the caller's original instance is verifiably
still unchanged afterward — `23_composite_param`), the same for an
array argument (`25_composite_array_param`), a struct return value used
in a decl-init (`24_composite_return`), a chained/nested call: reading
`f().field` directly (no intermediate named variable) **and** `g(f())`
(the result of a composite-returning call fed directly into another
composite parameter) in the same fixture
(`26_composite_chained_and_nested_call`), recursion with a composite
parameter **and** return type at once (`27_composite_recursion` —
proves that the temporary-area allocation/freeing story stays correct
under repeated, nested calls as well), a packed struct with a
not-divisible-by-8 size (two `int8` fields) both as an argument and as
a return value (`28_composite_packed_odd_size` — a concrete test of the
generalized alignment rounding), and a fixture expecting `codegen_fail`
for the deliberately out-of-scope case
(`29_composite_call_as_literal_field_deferred`, see Chapter 10) — the
latter uses the optional `.expected.codegen_exit` fixture convention
(see `run_codegen_tests.sh`).

---

## 9. Exit Codes — Addendum

The existing table (see `Hoare/README.md`) gets one new row added:

| Code | Meaning |
|---|---|
| `4` | Code generator error (`build/codegen` only). The program is **semantically valid**, but the requested construct falls outside this phase's scope (struct/array/pointer, user function call, multi-function program, etc.) — diagnostic to stderr, with the `codegen error:` prefix. Not to be confused with code 3 (semantic error): 4 never means invalid Postulate source, only something outside the compiler's current scope. |

Two more codes belong to a **compiled Postulate program**, not to
`build/codegen` itself — see Chapter 11. They only appear when the
program was compiled with `POSTULATE_STACK_CHECK=1` and the self-check
fired at runtime:

| Code | Meaning |
|---|---|
| `112` | Stack canary corrupted (out-of-bounds local write) — debug-only, `POSTULATE_STACK_CHECK=1` builds only. |
| `113` | Stack pointer imbalance at program exit — debug-only, `POSTULATE_STACK_CHECK=1` builds only. |

---

## 10. Known Items Deliberately Not Implemented in This Phase

Phase 1's list has effectively been covered by Phase 2, and Phase 3
closed the call-boundary question (a struct/array *value* can now
cross a user function-call boundary both as an argument **and** as a
return value, see Chapter 2 and 6.5-6.8). Two, much narrower items
remain open:

- **A composite-returning `CALL` used as a `STRUCT_LIT`/`ARRAY_LIT`
  field/element value.** `gen_init_push`'s (see 6.6) current
  two-category leaf model ("scalar value, pushed" or "nested literal,
  recursed into") does not account for a third category, "`CALL`,
  needs an address to write into" — pass 1's forward, push-only walk
  does not yet have a destination for this. A concrete, currently
  unaccepted example (cleanly rejected with `codegen_fail`, not
  generating incorrect code — via `gen_rvalue`'s `CALL` branch's
  existing guard, see 6.5, because `gen_init_push` tries to evaluate
  the `CALL` leaf as a simple scalar leaf, with `gen_rvalue`):

  ```postulate
  struct Point { x: int32; y: int32; }
  struct Line { start: Point; end: Point; }

  function make_point(x: int32, y: int32) : Point {
    return Point { x := x, y := y };
  }

  function main() : int32 {
    // end's initializer is a nested STRUCT_LIT -- this already works
    // (since Phase 2). start's initializer is a composite-returning
    // CALL -- this does NOT work yet: gen_init_push has no case for a
    // CALL leaf. codegen_fail with a clean diagnostic, instead of
    // generating incorrect code.
    mut l: Line := Line { start := make_point(1, 2), end := Point { x := 3, y := 4 } };
    return l.start.x;
  }
  ```

  A workaround that already works today: saving the call's result
  beforehand into a **named** local variable — `mut s: Point :=
  make_point(1, 2); mut l: Line := Line { start := s, end := ... };` —
  since a plain `IDENT` field-initializer value already works (since
  Phase 2), and `s`'s own decl-init from `make_point(1, 2)` is exactly
  Phase 3's basic case (see 6.5/6.7). Only the *direct, unnamed* call
  used as a field value is deferred. (`tests/codegen_cases/
  29_composite_call_as_literal_field_deferred.ptl` exercises exactly
  this rejected case.)
- **Composite-typed `BINARY` operators** (`==`, `<`, etc. on
  struct/array operands) — now rejected at the semantic-checking stage
  itself (`sema_expr.asm`'s `.binary_compare` rejects `AST_TY_ARRAY`/
  struct-name operands via `resolve_struct_type`, exit code 3, `semantic
  error: cannot compare struct/array values`), so `gen_rvalue`'s own
  `is_scalar_loadable_type` guard (see 6.5's induction argument) is now
  unreachable defense-in-depth rather than the primary enforcement.
- A composite (struct/array element-typed) array broadcast source (see
  6.6) — a rare case, deliberately rejected with `codegen_fail`, not
  part of the call-boundary question, unchanged since Phase 2.

These await a separate, not-yet-planned future phase; at that point
this document will be extended, not replaced.

---

## 11. Debug-Only Stack-Corruption Self-Check (`POSTULATE_STACK_CHECK`)

Test-harness instrumentation, not a language feature: `build/codegen`
consults its own process environment for `POSTULATE_STACK_CHECK=1`
(`codegen_main.asm`'s `_start`, before anything else runs — walks the
kernel-provided `envp[]` directly, no libc), setting the module-level
flag `stack_check_enabled` (`global`, consulted via `extern` from
`codegen_program.asm`). With the variable unset — every normal
invocation, and everything a real `hoare`-compiled program goes
through — `gen_program`/`gen_function`/`compute_local_offsets` emit
**exactly** what they did before this existed; no hidden cost for
production output, matching this project's no-hidden-runtime-cost
principle (see the top-level project overview). Set, two extra checks
get emitted:

### 11.1 Stack-pointer balance check

`gen_program` picks `s_header_checked` instead of the plain `s_header`
for the whole "before the first `pf_<name>:` label" block — same
`call pf_main` as before, wrapped with a balance check:

```nasm
BITS 64
section .bss
__pf_entry_rsp: resq 1
section .data
__pf_msg_imbalance: db 'runtime error: stack pointer imbalance detected at program exit', 10
__pf_msg_imbalance_len equ $ - __pf_msg_imbalance
__pf_msg_canary: db 'runtime error: stack canary corrupted -- out-of-bounds local write', 10
__pf_msg_canary_len equ $ - __pf_msg_canary
section .text
global _start

__pf_stack_check_fail:          ; in: r8=msg ptr, r9=msg len, r10=exit code
    mov     rax, 1               ; sys_write
    mov     rdi, 2                ; stderr
    mov     rsi, r8
    mov     rdx, r9
    syscall
    mov     rax, 60               ; sys_exit
    mov     rdi, r10
    syscall

_start:
    mov     [__pf_entry_rsp], rsp
    call    pf_main
    mov     rcx, rsp
    cmp     rcx, [__pf_entry_rsp]
    je      .balance_ok
    mov     r8, __pf_msg_imbalance
    mov     r9, __pf_msg_imbalance_len
    mov     r10, 113
    jmp     __pf_stack_check_fail
.balance_ok:
    ; ...unchanged: mov rdi, rax/0 + s_exit_tail, exactly as without the flag
```

`r8`/`r9`/`r10` carry the shared handler's parameters specifically
because they survive a raw `syscall` instruction untouched (unlike
`rcx`/`r11`, and unlike `rdi`/`rsi`/`rdx`/`rax`, which `sys_write`/
`sys_exit` themselves need) — one handler, reused by every call site
below, rather than duplicating the write+exit sequence per function.

**Coverage note**: because every function's own epilogue always does
`mov rsp, rbp` (see 11.2 and Chapter 4) before returning, a `push`/`pop`
or `sub`/`add rsp` mismatch *inside* one function's body can never by
itself propagate an imbalance out to its caller — that function's own
epilogue silently resets `rsp` from `rbp` regardless. This check mainly
catches a broken prologue/epilogue in the fixed skeleton itself, or an
imbalance injected directly around a `call` site (mirrored by
`tests/stack_check_cases/02_rsp_imbalance.asm`'s hand-written negative
fixture, since no real Postulate program can express this). The
per-function canary (11.2) is the check that actually fires for the
higher-likelihood bug class — an out-of-bounds local write.

### 11.2 Per-function stack canary

`compute_local_offsets` reserves 8 extra bytes when the flag is set (see
Chapter 4's addition) — `sub rsp, N` in the prologue always includes
that reservation, and right after it, `gen_function` emits:

```nasm
    mov     rax, 0x5CA1AB1E5CA1AB1E
    mov     qword [rbp - 8], rax
```

(`rax` is safe to clobber here — the incoming args-block pointer lives
in `rdi`, untouched until `emit_param_copy`'s loop runs later.) The
epilogue (`s_epilogue_checked`, replacing the plain `.epilogue`/
`mov rsp,rbp`/`pop rbp`/`ret` block wholesale) checks it back, wrapping
`rax` in a `push`/`pop` since a scalar-returning function's real return
value sits there and must survive the check untouched:

```nasm
.epilogue:
    push    rax
    push    rcx
    mov     rax, [rbp - 8]
    mov     rcx, 0x5CA1AB1E5CA1AB1E
    cmp     rax, rcx
    jne     .canary_bad
    pop     rcx
    pop     rax
    mov     rsp, rbp
    pop     rbp
    ret
.canary_bad:
    pop     rcx
    pop     rax
    mov     r8, __pf_msg_canary
    mov     r9, __pf_msg_canary_len
    mov     r10, 112
    jmp     __pf_stack_check_fail
```

The canary sits at `[rbp - 8]` — immediately below the saved `rbp`/
return address, and (per Chapter 4's array-indexing direction: an
array's element 0 sits at the *low*-address end of its slot, with
increasing index moving toward *higher* addresses, i.e. toward `rbp`)
directly in the path of an out-of-bounds write that walks past the end
of an array/struct local, before it could reach the saved frame pointer
or return address. `.epilogue`/`.canary_bad` are local labels (NASM
scopes them to the nearest preceding global label, `pf_<name>:`), so no
manual per-function uniquing is needed despite every function sharing
the same label text.

### 11.3 Testing

`tests/stack_check_cases/*.asm` — hand-written NASM (not `.ptl`; the
language has no way to deliberately corrupt the stack), each matching
the instrumented shape exactly with **one** injected bug isolating one
check: `01_clean_ok.asm` (no bug, must exit 0 — a false-positive check),
`02_rsp_imbalance.asm` (an extra `push` before `call pf_main`, simulating
a leaked caller-side reservation — must exit 113), `03_canary_corrupted
.asm` (an out-of-bounds-style overwrite of `[rbp - 8]` inside `pf_main`'s
own body — must exit 112). `scripts/run_stack_check_tests.sh` additionally
recompiles every `tests/codegen_cases/*.ptl` fixture that normally
succeeds (skipping the `.expected.codegen_exit` ones — the flag cannot
change a compile-time rejection) with the flag on, executes the result,
and asserts the *same* expected exit code/stdout as the unflagged suite
already checks — the actual regression net, proving the current compiler
leaves no stack corruption behind across the whole real fixture set.
