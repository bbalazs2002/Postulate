# `v1.0.3` design: composite (struct/array) values across a call boundary

## Scope

This is the implementation design for step `v1.0.3` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md): struct/
array parameters and return values in `Stage1/src/codegen.ptl` — v0
parity (composites are already fully legal v0, passed/returned by
value with full independent-copy semantics, `postulate_v0_language_
reference.md` §3.9), not a new v1 feature. Landed in internally ordered
sub-passes, all still `v1.0.3`:

1. **Width unification** (**done**): every scalar value switches from
   `v1.0.2`'s uniform `i64` representation to its own true declared
   LLVM width.
2. **Structs — locals, fields, literals, copy** (**done**): struct-
   typed locals, field read/write (including nested field chains),
   struct literals (including nested), and struct-to-struct copy.
   Struct-typed *parameters and return values* are deliberately still
   out of scope here — `type_ok` (the check gating parameter/return
   types) is untouched, only `type_ok_local` (a new, decl-only check)
   accepts structs. Arrays and pointers are also still out of scope.
3. **Arrays — locals, indexing, literals, broadcast-init, copy**
   (**done**): array-typed locals, index read/write (including chained
   index/field lvalues like `pts[1].x`), array literals (including
   array-of-struct and nested arrays), scalar broadcast-init, and
   array-to-array copy. Same scope boundary as structs — array-typed
   parameters/return values are still out of scope (`type_ok`
   unchanged), and so are pointers (`&`/`*`).
4. **Pointers and the calling convention** (not yet done): `&`/`*`, and
   composite parameters/return values (removing the `type_ok`
   restriction above). This section of the document will be written
   when that sub-pass lands.

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

## Sub-pass 2: structs — locals, fields, literals, copy

### Packed named struct types, declared once

Every declared `struct` gets one `%struct.<Name> = type <{ Field1,
Field2, ... }>` line, emitted once at the very top of the output
(`emit_struct_types`, before `_start`), in declaration order — order
is only for determinism, not correctness, since LLVM type definitions
can reference another named type by name regardless of textual order
(unlike C). Every other use site (an `alloca`, a `load`/`store`, a
`getelementptr`) then just references the short name (`emit_struct_
type_ref`) rather than re-spelling the packed field list every time —
simpler for nested/repeated use, and avoids the exponential blowup
re-expanding nested struct types inline would risk. `<{ ... }>`
(LLVM's *packed* struct syntax) is what gives the zero-padding layout
decision 2 (see "Scope" above) for free — nothing computes byte offsets
by hand anywhere in this file; `getelementptr` addresses a field by its
declaration-order *index*, and LLVM's own lowering turns that into the
correct packed byte offset.

### A struct table, mirroring the function table exactly

`build_struct_table`/`struct_lookup` are `build_func_table`/
`func_lookup`'s own shape, for `AST_STRUCT_DECL` (kind 35) instead of
`AST_FUNCTION` — name → the struct's own top-level node id, resolved
once per program before any codegen (so a struct may be referenced
before its own declaration, same forward-reference story functions
already have). `struct_field_lookup` finds a named field within one
struct's own declaration, returning both its declaration-order index
(for `getelementptr`) and its own type node (for reads/writes and for
recognizing a *nested* struct field).

### Every composite `ExprResult`/`SymInfo` is address-shaped, never a loaded value

`ExprResult` and `SymInfo` both gained `is_composite`/`struct_node`
fields alongside their existing scalar `width`/`is_signed`. The load-
bearing design choice: **a composite `ExprResult`'s `reg` is always an
address**, never a "loaded aggregate value" SSA register — a struct-
typed local's `reg` is simply its own `alloca`'s address (no load
needed to produce it as an expression result); a struct literal's
`reg` is a freshly `alloca`'d temporary's address, filled in field by
field. This sidesteps ever needing `insertvalue`/whole-aggregate SSA
values in this sub-pass at all — only a genuine *consumer* of a
composite value (a decl-init, an assignment, a struct-literal field
whose own value is itself a nested struct) ever does the one `load`
(from the source address) + `store` (into the destination address)
pair that actually copies it, always keyed by the same `%struct.<Name>`
type on both sides. This works only because every composite-valued
expression *in this sub-pass* is already naturally address-shaped
(a variable, a field, a literal) — a struct-returning function call
(sub-pass 3) will need to decide how to produce an address for a
call's result too, but that's this sub-pass's problem to hand off, not
solve now.

### `gen_lvalue`: the address-producing counterpart `gen_expr` didn't need before

`AST_EX_IDENT` reuses the symbol table directly (unchanged from before
— a local's alloca *is* its address). `AST_EX_FIELD` recurses into its
own base via `gen_lvalue` first (which must itself resolve to a
struct-typed address — reading through a non-struct or a failed base
is a clean codegen error, not a crash), then one `getelementptr` step
to the named field, via `struct_field_lookup`'s index. `gen_expr`'s own
`AST_EX_FIELD` case is exactly "`gen_lvalue`, then `load` only if the
field turned out to be scalar" — mirroring Hoare's own Phase 2
`gen_lvalue`/`gen_rvalue` split (`docs/postulate_stage0_codegen_spec.md`).
`AST_EX_INDEX` (arrays) and `UNARY(*)` (pointer deref) are not handled
by `gen_lvalue` yet — sub-pass 3.

### Struct literals: alloca, then GEP + store per named field

`gen_struct_lit` resolves the struct name, `alloca`s one fresh
temporary of that type, then for each `field := expr` in the literal
(source order, not necessarily declaration order): resolves the field
name against the struct's own declaration (an unmatched name is a
codegen error, per this file's "never silently wrong" rule, not
silently skipped), `getelementptr`s to that field's address, evaluates
`expr` via ordinary `gen_expr` (which recurses correctly into a nested
struct literal, since that's just another composite `ExprResult`), and
either coerces+stores a scalar value or does the load+store composite-
copy pair for a nested-struct field value. Array broadcast-init and
composite-array literals are sub-pass 3's concern.

### Assignment gains `AST_EX_FIELD` lvalues, alongside plain idents

`gen_assign_stmt`'s pass 2 now calls `gen_lvalue` (any of `AST_EX_
IDENT`/`AST_EX_FIELD`) instead of a direct `sym_find`-only lookup, then
branches the same way `gen_decls` does: coerce+store for a scalar
target, or the load+store composite-copy pair for a struct target
(whose staged pass-1 rhs must itself have been composite — a scalar rhs
assigned to a struct lvalue, or vice versa, is a clean codegen error).

## Testing (sub-pass 2, structs)

All end-to-end (assembled with `llc`, linked with `ld`, actually
**run**), in `Stage1/tests/codegen_cases/03_struct_field_literal_
copy.ptl`: a two-field packed struct (`int8` next to `int32`, proving
non-8-byte-aligned packed layout, not just same-width fields) nested
inside a two-field outer struct; a nested struct literal as a field's
own initializer value; chained field access through the nesting
(`l.start.x`); a full-struct copy (`l2 := l`) followed by independent
mutations on *both* copies, proving true copy isolation in both
directions (exit code 124, only correct if every copy is a real,
independent instance — an aliasing bug would produce a different
number). Also verified, ad hoc: a struct-typed function parameter is
still cleanly rejected with `codegen error` and exit code 1 (`type_ok`,
gating parameters/returns, is untouched by this sub-pass — confirms
the scope boundary actually holds, not just that it's documented).

## Testing (sub-pass 3, arrays)

All end-to-end, in `Stage1/tests/codegen_cases/04_array_index_literal_
broadcast.ptl`: array literal decl-init, index read/write, array-to-
array copy with independent mutation on *both* copies (mirroring the
struct copy-isolation test), an array-of-struct literal (each element
itself a nested struct literal), scalar broadcast-init, and a chained
index+field lvalue (`pts[1].x := 100`). Also verified, ad hoc: an
array-typed function parameter is still cleanly rejected with
`codegen error` (same as a struct-typed one), and a plain pointer
declaration/dereference (`&x`, `*p`) is also still cleanly rejected —
confirming both scope boundaries actually hold.

## Sub-pass 3: arrays — locals, indexing, literals, broadcast-init, copy

### `ExprResult`/`SymInfo` grow a parallel array description, not a unified "type node"

A struct's composite description (`struct_node`, the resolved
`AST_STRUCT_DECL`) can't simply generalize to "the value's own type
AST node," because a *literal* (struct or array) has no existing type-
annotation node to point back to — only a name (struct) or nothing at
all (array), resolved once at construction time into whatever's
actually needed downstream. So `ExprResult`/`SymInfo` gained a second,
parallel description alongside `struct_node`: `is_array` (the
discriminator), `elem_type` (the element's own type node — itself
possibly composite, recursing) and `elem_count` (the declared size).
Exactly one of "struct" or "array" applies whenever `is_composite` is
true; `emit_composite_type` is the one place that dispatches on
`is_array` to spell either shape's LLVM type.

### Array literals cannot infer their own type — unlike struct literals

`{1, 2, 3}` carries no name and no declared type of its own; v0 infers
it entirely from context (a decl's declared type, or a struct/array
literal's own field/element type — the only two places a bare array
literal is valid this sub-pass). `gen_expr`'s generic dispatch has no
such context, so its own `AST_EX_ARRAY_LIT` case is a deliberate,
permanent no-op that fails cleanly — the *real* entry point is
`gen_array_lit_typed(bufs, gst, node, elem_type, elem_count)`, called
directly by whichever caller already knows the target shape:
`gen_decls`' array branch (the decl's own declared element type/
count), and `gen_struct_lit`'s field-value handling (a field's own
declared type, when that field's value is itself a bare array
literal — checked via the AST node's own kind, `(*bufs.pool_kind)
[fval_node] == 20`, before ever calling generic `gen_expr` on it). A
*nested* array literal (an element of another array literal, one level
of `elem_type` down) recurses into `gen_array_lit_typed` again, the
same way `gen_struct_lit` already recurses into ordinary `gen_expr`
for a nested struct-literal field.

### Indexing: `AST_EX_INDEX` in `gen_lvalue`, mirroring `AST_EX_FIELD`

Recurses into its own base first (must resolve to an array-typed
address), then one `getelementptr` step — `i64 0, i64 %v<idx>` instead
of a field's constant `i32 0, i32 <index>`, since an array index is a
*computed* value (any expression, coerced to `i64` first via
`coerce_width`), not a compile-time constant. Two GEP-suffix pieces
exist for exactly this reason: one bakes in `%v` (a real index
register, used here), the other doesn't (a literal position number,
used by `gen_array_lit_typed`/broadcast-init below to address element
*N* directly by its own loop counter) — **conflating the two was a
real bug caught during testing** (see below), not just a hypothetical
one worth footnoting.

### Broadcast-init: coerce once, store N times

A scalar decl-init source for an array-typed decl (`mut a: int32[4] :=
7;`, v0 reference §4.1) is coerced to the element type exactly once,
then the *same* already-coerced register is stored into each of the
`elem_count` GEP'd element addresses in a compile-time-bounded loop (the
count is always a literal in v0 — no need to re-evaluate or re-coerce
per iteration). A composite broadcast source is rejected before this
path is ever reached (checked alongside the composite-array-copy case,
both branches of "the decl-init's own `gen_expr` result was
composite") — matching Stage 0's own rule (Hoare's checker never
allows a composite broadcast source either), not a Stage-1-only
restriction invented here.

### `emit_composite_copy`: one helper for every whole-aggregate copy

By the time arrays needed the exact same "one `load` from a source
address, one `store` into a destination address, using the value's own
LLVM type both times" shape structs already used in three places
(`gen_decls`, `gen_assign_stmt`, `gen_struct_lit`'s nested-field case),
factoring it into a single `emit_composite_copy(bufs, gst, is_array,
struct_node, elem_type, elem_count, src_addr, dst_addr)` helper — used
by all five call sites now (the three above, plus `gen_decls`' new
array branch and `gen_array_lit_typed`'s own nested-element case) — was
clearly worth it, rather than hand-duplicating the same six lines a
fifth time.

### A real bug this sub-pass's own testing caught

`gen_array_lit_typed`'s and the broadcast-init loop's own element GEPs
both initially reused the *dynamic*-index piece (the one baking in
`%v`) with a **literal loop counter** appended after it — producing
`getelementptr [N x T], ptr %vBase, i64 0, i64 %v2` (a bogus reference
to *register* `%v2`) instead of `..., i64 2` (the literal element
position). This compiled cleanly (the bug is only a *type* mismatch,
not a syntax error) but failed at `llc`'s own verifier
(`'%vN' defined with type 'ptr' but expected 'i64'`) the first time an
array-literal/broadcast-init fixture was actually run through the full
pipeline — exactly the kind of error this project's "build and run,
don't just compile" discipline exists to catch, and did.

## Sub-pass 4: pointers and the calling convention

Not yet implemented — see the bootstrap plan's own `v1.0.3` entry and
this document's "Scope" section above. Will be written up here once
landed: `&`/`*` (pointer values, `UNARY` codegen for ops 71/72), and
the calling convention (composite parameters/return values, removing
`type_ok`'s current scalar-only restriction and extending the function
table to record full parameter/return types rather than just void-or-
not).
