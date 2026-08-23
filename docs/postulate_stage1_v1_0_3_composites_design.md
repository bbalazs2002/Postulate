# `v1.0.3` design: composite (struct/array) values across a call boundary

## Scope

This is the implementation design for step `v1.0.3` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md): struct/
array parameters and return values in `Stage1/src/codegen.ptl` — v0
parity (composites are already fully legal v0, passed/returned by
value with full independent-copy semantics, `postulate_v0_language_
reference.md` §3.9), not a new v1 feature. Landed in two internally
ordered sub-passes, both still `v1.0.3`:

1. **Width unification** (this document's current content, **done**):
   every scalar value switches from `v1.0.2`'s uniform `i64`
   representation to its own true declared LLVM width.
2. **Composites** (not yet done): struct/array types, literals, field/
   index access, copy, broadcast-init, and the calling convention. This
   section of the document will be written when that sub-pass lands.

## Sub-pass 1: width unification

### Why this had to happen before composites, not after

Adding real struct support means giving struct fields their true
declared byte size — v0's own layout guarantee (§2.6: "packed — no
padding between fields") only comes out correct if a field's LLVM type
actually matches its declared width. If fields kept `v1.0.2`'s uniform
`i64` representation, an array of structs would compute the wrong
element-to-element stride (`Point[10]`'s spacing must equal the true
packed `sizeof(Point)`), silently corrupting data the moment array-of-
struct indexing was used. Once a struct field's *type* is genuinely
narrower than `i64`, keeping *bare* scalars artificially uniform at
`i64` would mean a constant zext/trunc boundary between "ordinary
value" and "struct field" domains — worse, and no less code, than just
having one consistent rule everywhere. So: every value, not only future
composite fields, now uses its true declared width.

**Accepted side effect, not a free lunch:** this also fixes `v1.0.2`-
and-earlier's "no truncation on overflow" simplification — narrow-type
arithmetic (`int8`, `int16`, `uint8`, `uint16`) now wraps correctly,
matching true v0/Hoare semantics. That is a real behavior change beyond
a pure backend swap, made *deliberately* as part of this step (see
`Stage1/tests/codegen_cases/02_narrow_type_wraparound.ptl`), not as an
accidental side effect nobody decided on.

**Explicitly unchanged:** comparisons, division, and modulo are still
always emitted as *signed* LLVM operations regardless of an operand's
actual declared signedness — the same documented simplification this
file has always had, on a different axis (signedness, not width) from
what this step touches.

### Type-to-width table

`type_width` (`Stage1/src/codegen.ptl`): `int8`/`uint8` → `i8`,
`int16`/`int`/`uint16`/`uint` → `i16` (`int`/`uint` are v0's own plain
aliases for the 16-bit forms, §2.1, not separate widths), `int32`/
`uint32` → `i32`, `int64`/`uint64` → `i64`, `bool` → `i1`.

### Coercion: `coerce_width`

A single helper (`Stage1/src/codegen.ptl`) emits a `trunc`/`sext`/
`zext` whenever a value crosses into a context of known width, and is
a no-op otherwise. Every one of the following is exactly such a
crossing point:

- **An untyped integer literal** (v0 §3.7 — no declared width of its
  own) defaults to materializing as `i64`; whichever consumer stores or
  combines it into a width-known context narrows it down. A `bool`
  literal is never "untyped" this way (§2.2: never interchangeable with
  an integer type) — it's always exactly `i1` from the start.
- **A binary operator's two operands** are coerced to their shared
  *narrower* width before the op is emitted (`gen_binop`) — this is
  what makes `x + 5` work when `x` is `int8` and `5` defaulted to
  `i64`. For two operands that are both real (non-literal), differently
  -declared-width variables — not valid v0 (the checker this file
  doesn't run would reject it) — the same narrowing rule applies
  deterministically rather than being special-cased, consistent with
  this file's existing "garbage in, garbage out" stance elsewhere.
- **A decl-init, an assignment, or a `return expr;`** coerces the
  source expression to the target's (the decl's, the lvalue's, the
  function's declared return type's) width before storing.
- **A user-function call argument** coerces to the callee's own
  declared parameter width, looked up directly from the callee's AST
  node (see "Function table" below) — not a fixed `i64` slot the way
  `v1.0.2` assumed.
- **A raw syscall argument** (`gen_extern_call`) always coerces to
  `i64` — the raw Linux syscall ABI uses full 64-bit registers
  regardless of what width the Postulate-level expression itself
  naturally computed.
- **A branch condition** (`if`/`while`/`&&`/`||`) is coerced to `i1`
  defensively before being used as `br i1`'s operand — a no-op for any
  well-typed program (where it's already `i1`, since only `bool`
  operands are valid there), but this avoids ever emitting outright
  invalid LLVM IR (which `llc` would hard-reject) on slightly-off
  input, a worse failure mode than this file's usual "wrong number, but
  it runs" gaps.

Widening direction (`sext` vs `zext`) uses the *source* expression's
own signedness — there is no checker here to consult the target's, so
this is a deterministic, not necessarily "correct for genuinely
ill-typed input" choice, the same spirit as every other gap this file
already documents.

### A welcome simplification: comparisons need no post-widening

Because `bool` is now genuinely `i1` everywhere (not `v1.0.2`'s "0/1
packed into a full i64"), an `icmp`'s result — already `i1` in LLVM —
needs no `zext` back to a uniform width the way `v1.0.2` required, and
every place a boolean value is *consumed* (a branch condition, a
`bool`-typed store) can use it directly. `gen_and`/`gen_or`'s alloca-
backed short-circuit slot is `alloca i1` (storing `0`/`1` there is
already the correct `i1` shape); the `icmp ne i64 %v, 0` step
`v1.0.2` needed to turn a "0/1-in-i64" value into a real branch
condition is gone entirely.

### Function table: AST-node based, not a cached flags array

`v1.0.2`'s function table cached one flag per function (void or not).
Once a call site needs to coerce each argument to the *callee's own*
declared parameter width, and the call's own result register to the
callee's declared return width, a single flag isn't enough. Rather than
grow the cache to a second parallel array (widths), `build_func_table`
now stores each function's own top-level `AST_FUNCTION` node id, and a
call site (`gen_user_call`) walks that node directly — its signature's
param list, its return-type node — via the same `type_width`/
`type_is_signed` helpers everything else uses. This generalizes for
free to whatever `v1.0.3`'s composite sub-pass needs next (arbitrary
declared types, not just scalar widths) — the lookup shape doesn't
change, only what's read off the node once found.

### `main`/`_start`: `main`'s own declared return width, not assumed `i64`

`_start` now calls `pf_main` at `main`'s own true declared return
width (`main_return_type` returns the return-type node, `0` for void,
mirroring `AST_FUNCTION`'s own field), zero/sign-extending the result
to `i64` before the exit syscall only if `main`'s return type isn't
already 64 bits — `v1.0.2` assumed `i64` unconditionally. (The exit
syscall's observable exit code only depends on the low 8 bits either
way, so `zext` is used unconditionally here rather than branching on
`main`'s signedness — a harmless simplification, not a behavior gap.)

## Testing (sub-pass 1)

Same corpus `v1.0.2` was verified against, run through the width-
unified backend, same exit codes throughout — proving the swap changes
nothing observable *except* the one deliberate fix:

- All 12 scalar-only `Hoare/tests/codegen_cases/*` fixtures
  (`01`–`10`, `19`, `20`) — identical exit codes to `v1.0.2`.
- All 16 `include_cases` fixtures, plus the `v1.0.2` eval-order fixture
  (`Stage1/tests/codegen_cases/01_arg_eval_order_left_to_right.ptl`) —
  unchanged.
- New: `Stage1/tests/codegen_cases/02_narrow_type_wraparound.ptl` —
  positive proof of the width-unification behavior change itself
  (`int8` overflow now wraps; exit code `1`, not `0`).
- A void-user-function-call smoke test, re-verified against the
  redesigned (node-based) function table.

## Sub-pass 2: composites

Not yet implemented — see the bootstrap plan's own `v1.0.3` entry and
this document's "Scope" section above. Will be written up here once
landed: type-to-LLVM-type rendering (including the struct table and
packed-struct decision), `gen_lvalue`, literal/broadcast-init codegen,
and the calling convention.
