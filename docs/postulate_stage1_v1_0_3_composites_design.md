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
   array-of-struct and nested arrays), broadcast-init (scalar *or*
   struct source, both at decl-init and at assignment — see "Broadcast-
   init" below), and array-to-array copy. Same scope boundary as
   structs — array-typed parameters/return values are still out of
   scope (`type_ok` unchanged), and so are pointers (`&`/`*`).
4. **Pointers, scalar pointee** (**done**, split from the original
   combined "pointers and the calling convention" plan the same way
   structs/arrays were split earlier — see "Sub-pass 4a" below):
   `&`/`*`, `null`, pointer-typed locals/parameters/return values,
   pointer assignment and `==`/`!=` comparison — restricted to a
   pointee that is itself a plain scalar type (`*int32`, not `*Point`
   or `*int32[3]` or `**int32`). Struct/array pointees, and the
   composite calling convention (struct/array-typed parameters/return
   values), remain out of scope — see "Sub-pass 5a"/"Sub-pass 5b" below.
5. **The calling convention** (**done**, split again the same way —
   see "Sub-pass 5a" below): struct/array-typed parameters and return
   values, by value, with full independent-copy semantics — v0 parity
   (`type_ok`'s scalar-only restriction removed for parameters/return
   values, reusing `type_ok_local`'s existing struct/array/pointer
   classification instead of a separate check). Pointers with a
   composite pointee (`*Point`, `*int32[3]`) remain out of scope — see
   "Sub-pass 5b" below.
6. **Composite pointees** (not yet done): struct/array-typed pointers
   (removing the scalar-only restriction `type_ok_local`'s pointer
   branch still imposes on the pointee). This section of the document
   will be written when that sub-pass lands.

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

The struct-source/assignment-time broadcast extension (see "Broadcast-
init" above) added its own permanent fixture,
`Stage1/tests/codegen_cases/05_struct_array_broadcast.ptl`: struct
broadcast at decl-init (`mut pts: Point[4] := p;`) with a subsequent
per-element mutation proving copy independence, and scalar broadcast at
*assignment* (`nums := 7;` after `nums` was already declared) with its
own independent element mutation. Verified by hand-computed exit code
(`263 mod 256 = 7`). Also verified ad hoc (rejected cleanly with
`codegen error`, not a silent miscompile): a struct source broadcasting
into an array whose element type is a *different* struct (`A[3] := b;`
where `b: B`, even though `A`/`B` have identical field layouts — the
check is by declared struct identity, matching Hoare's own
`types_equal`, not by structural shape), and a scalar source
broadcasting into a struct-typed array element (`arr: A[3] := 5;` —
`type_width` has no meaningful answer for a struct type node, so this
is guarded explicitly rather than left to silently fall through to a
type-mismatched `store` that only `llc`'s verifier would have caught).

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

### Broadcast-init: coerce/copy once, store N times — scalar or struct source, decl-init or assignment

A scalar decl-init source for an array-typed decl (`mut a: int32[4] :=
7;`, v0 reference §4.1) is coerced to the element type exactly once,
then the *same* already-coerced register is stored into each of the
`elem_count` GEP'd element addresses in a compile-time-bounded loop (the
count is always a literal in v0 — no need to re-evaluate or re-coerce
per iteration).

Initially this path rejected any composite broadcast source outright,
on the assumption v0 only allows a scalar broadcast source — checking
Hoare's own semantic checker (`Hoare/src/sema_stmt.asm`,
`check_array_broadcast_compatible`) showed that assumption was too
narrow: Hoare accepts *any* expression whose type matches the array's
element type exactly, as long as it isn't literally an array literal —
which includes a **struct-typed source broadcasting into an array-of-
struct**, not just scalars. This was added as a second broadcast shape,
alongside the scalar one: when the decl-init's own `gen_expr` result is
composite-but-not-array, and the array's own element type resolves (via
`type_ok_local`) to a struct exactly matching the source's `struct_node`,
the same per-element GEP loop runs `emit_composite_copy` (a whole-
aggregate load+store) into each element address instead of a scalar
`coerce_width`+store. A source struct that doesn't match the element
type's struct (or a scalar source against a struct-typed element, where
`type_width` has no meaningful answer) is rejected with a codegen error,
not silently miscompiled.

Hoare's checker also confirmed broadcast-init isn't decl-init-only:
`postulate_v0_language_reference.md` §4.2 already states an assignment's
right-hand side "match[es] the same shapes and rules as a `decl`
initializer," and `check_array_broadcast_compatible` is in fact called
from *both* `check_decl` and the assignment-statement checker in Hoare.
`gen_assign_stmt` initially didn't implement either broadcast shape at
all (an array-typed assignment target required an exact array-to-array
`emit_composite_copy`, nothing else) — this sub-pass closed that gap
too, mirroring `gen_decls`' own scalar/struct broadcast logic exactly
(same GEP-per-element loop, same struct-match/scalar-vs-struct-element
guards), so `arr := 7;` and `arr := some_struct;` now work identically
whether `arr` is being declared or merely reassigned.

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

## Sub-pass 4a: pointers, scalar pointee

### Scope narrowed the same way structs/arrays were

The original plan (this document's own point 4/8, and the bootstrap
plan's `v1.0.3` entry) bundled "pointers" and "the calling convention"
into one sub-pass. In practice, pointers turned out to be a large
enough feature on their own — a pointer value is a genuinely *third*
value kind (parallel to scalar and composite, not a variant of either),
and `&expr` has to work on any lvalue shape — so, matching the earlier
struct-then-array split, this landed as its own increment, scoped down
by explicit choice to a **scalar pointee only**: `*int32`, `*bool`,
etc., not `*Point` (struct pointee), not `*int32[3]` (array pointee,
which is also how a bare array-of-pointers `*T[N]` reads under the v0
grammar's own `*T[N]`/`*(T[N])` distinction, §2.5), and not `**int32`
(pointer-to-pointer). Composite pointees, and the composite calling
convention itself, are Sub-pass 5, not yet done.

### A pointer value is a third `ExprResult`/`SymInfo` kind, not a struct/array variant

`is_composite` values are always addresses (`reg` points at the
aggregate); ordinary scalars are always values (`reg` holds the value
itself, already loaded). A pointer value doesn't fit either shape
cleanly enough to reuse them: it's a *single register value* like a
scalar (no GEP/load-store aggregate machinery needed), but its LLVM
type is always the opaque `ptr`, not `i<width>`. So `ExprResult`/
`SymInfo`/`TypeOkResult` each gained a third discriminator,
`is_pointer`, alongside `is_composite`/`is_array`. Since LLVM's opaque
pointers erase the pointee type entirely at the IR level (a `ptr` is a
`ptr` regardless of what it points to), there's no need to carry a
pointee *type node* around the way an array carries its `elem_type` —
only the pointee's *width*/*signedness* are ever actually needed (to
know what `*p` should `load`), so `ExprResult`/`SymInfo` simply reuse
their existing `width`/`is_signed` fields to mean "the pointee's width/
signedness" when `is_pointer` is true, exactly the same kind of
context-dependent field reuse `elem_type` already has between the
struct/array cases. `TypeOkResult` (which has no baseline `width`/
`is_signed` fields to reuse) gained two small dedicated ones,
`ptr_width`/`ptr_signed`, instead.

### `&expr` is free — `gen_lvalue`'s own "reg is always an address" convention already computed it

`gen_lvalue` (the composite sub-passes' own address-producing
counterpart to `gen_expr`) already hands back, for any plain scalar
lvalue, an `ExprResult` whose `reg` is the address of that lvalue —
not yet loaded, by design, so `gen_expr`'s own `AST_EX_FIELD`/
`AST_EX_INDEX` dispatch can decide whether to load it. `&expr` needs
exactly that address, as its *own* value — so `UNARY(&)` (op 72) is
just `gen_lvalue(expr)` followed by a *reclassification* (scalar
address → pointer value), not a new instruction. Composite and already-
pointer lvalues are rejected here (`inner.is_composite || inner.is_pointer`)
since their address would need a composite or pointer-to-pointer
pointee, both out of this sub-pass's scope.

### `*expr` splits the same way `s.field`/`a[i]` already did

`UNARY(*)` (op 71) needs two different codegen shapes depending on
position, mirroring `gen_expr`'s existing `AST_EX_FIELD`/`AST_EX_INDEX`
split with `gen_lvalue`:

- **As an rvalue** (`x := *p;`): handled directly in `gen_expr`'s own
  `AST_EX_UNARY` case — evaluate `p` as an ordinary *value*
  (`gen_expr`, not `gen_lvalue`: its pointer value, not its address, is
  what gets dereferenced), then one `load` using the pointee's own
  width, producing a plain scalar `ExprResult` (this sub-pass's
  scalar-pointee restriction means the loaded value is always scalar).
- **As an lvalue** (`*p := 5;`): a new `gen_lvalue` case. Same
  evaluation of `p` as a value, but the pointer value itself directly
  *becomes* the address `gen_lvalue` hands back — no `load` at all,
  matching every other `gen_lvalue` case's "reg is the address" rule.

### `null`: untyped like an int literal, but needs no width coercion at all

v0's untyped-constant rule (reference §3.7) says `null` "adopts"
whatever pointer type context expects, the same way a bare int literal
adopts its context's width. For an int literal that adoption is real
work (`coerce_width` truncates/extends the default `i64` materialization
down to the actual target width) — but a pointer's LLVM type is `ptr`
unconditionally, regardless of postulate-level pointee, so there is no
equivalent narrowing step. `null` materializes once, context-free, as
`%vN = inttoptr i64 0 to ptr`, and that single value is already correct
everywhere a pointer is expected — no per-use-site coercion, unlike int
literals.

### Comparison: `==`/`!=` only, checked before `gen_binop` ever sees it

v0's pointer rules (reference §2.3) allow "plain assignment/comparison
of the pointer value itself" but no arithmetic and (per this sub-pass's
own narrower reading) no ordering — pointers aren't signed/unsigned
integers, and `gen_binop`'s comparison ops are hard-coded signed `icmp`
regardless of operand signedness (an existing, documented
simplification), which has no sensible reading for a pointer. Rather
than teach `gen_binop` itself about pointers, `gen_expr`'s own
`AST_EX_BINARY` dispatch intercepts the case where either operand is a
pointer *before* calling `gen_binop`: both operands must be pointers
and the operator must be `==`/`!=` (op 61/62), or it's a clean codegen
error. `gen_binop` itself is completely untouched — zero risk to any
existing scalar arithmetic/comparison path.

### Assignment and decl-init: a direct `store`/`load`, no `coerce_width`

Both `gen_decls`' new pointer branch and `gen_assign_stmt`'s new
pointer branch are direct `store ptr %v, ptr %vslot` — no
`coerce_width` call, since there is no meaningful narrowing/widening
between pointer values under opaque `ptr` (unlike every scalar
assignment, which always goes through `coerce_width` to the target's
declared width). Both also explicitly guard against a pointer/non-
pointer shape mismatch (`is_pointer` disagreeing between the lvalue and
the rhs) rather than silently feeding a pointer's address-shaped `reg`
into `coerce_width`, which has no meaningful reading of a pointer
value's own "width" (that field means the *pointee's* width, per the
`ExprResult` header above) and would either misinterpret it as some
arbitrary integer width or produce a type-mismatched `trunc`/`zext` on
a `ptr`-typed operand — the same "reject cleanly, don't let a stale
field meaning masquerade as a real value" discipline this file already
applies everywhere else.

### Parameters and return values: `type_ok` untouched, a parallel check added at each call site

Unlike composites, a pointer value doesn't need the calling-convention
machinery `type_ok`'s scalar-only restriction exists to defer — it's a
single 8-byte register value, passed/returned exactly like a scalar
except its LLVM type is `ptr` instead of `i<width>`. So pointer-typed
parameters and return values are supported *now*, without touching
`type_ok` itself (still scalar-only, unchanged) or the calling-
convention question at all: `gen_function`'s signature/param/epilogue
code and `gen_user_call`'s argument/return code each gained their own
`is_pointer_type_node` branch alongside the existing `type_ok` check,
spelling `ptr` instead of `i<width>` and skipping `coerce_width` the
same way the decl/assignment paths do. `gen_user_call` also now
verifies each argument's pointer-ness against the callee's *declared*
parameter type (looked up the same way its width already was) and
rejects a mismatch (`&x` passed where a plain `int32` param is
declared, or vice versa) rather than silently mishandling it.
`gen_extern_call` (`sys_read`/`sys_write`/`sys_exit`) rejects a pointer
argument outright — passing a buffer pointer to a raw syscall is a
reasonable future feature but wasn't part of this sub-pass's scope, and
`coerce_width`ing a pointer's `reg` there would have the same "wrong
field, wrong instruction" failure mode as everywhere else this sub-pass
guards against it.

## Testing (sub-pass 4a, pointers)

End-to-end (`llc`+`ld`+actually **run**), via `Stage1/tests/codegen_
cases/06_pointers.ptl`: `&`/`*` round-tripping through a local
(`*p := 99;` observed through the original variable), `null` compared
with `==` and then reassigned via `&`, a pointer argument mutated
through a `void` function (`*p := *p + 1;`), a pointer *returned* from
one function and passed into another, and a second `==`-null branch
taken on a pointer that itself came back from a function call.
Verified by hand-computed and Docker-confirmed exit code
(`96 mod 256 = 96`). Also verified ad hoc (all cleanly rejected with
`codegen error`, not silently mishandled): `&pt` where `pt` is a
struct-typed local (composite pointee, out of scope), `&p` where `p`
is itself a pointer-typed local (pointer-to-pointer, out of scope —
caught two independent ways: the `**int32` declaration's own pointee
fails `type_ok`, and separately `&p`'s own `inner.is_pointer` guard
would reject it even if the declaration had been accepted), and a
pointer argument (`&x`) passed to a function whose declared parameter
type is a plain `int32`.

## Sub-pass 5a: the calling convention

### `type_ok_local` doubles as the parameter/return check — no separate classifier needed

The whole reason `type_ok`/`type_ok_local` were kept as two separate
checks since the struct sub-pass was to preserve a scope boundary:
composite-typed *locals* were fine, composite-typed *parameters/return
values* weren't, yet. Once that boundary itself is the thing being
removed, there's no need for a third, parallel classifier — every call
site that used to gate on `type_ok(ptype)` (`gen_function`'s signature/
param/retslot/epilogue code, `gen_user_call`'s argument/return code)
now calls `type_ok_local(ptype)` instead and branches on its existing
`is_struct`/`is_array`/`is_pointer` fields, exactly the same
classification `gen_decls` has used for locals since the struct/array
sub-passes. `type_ok` itself is untouched — still scalar-only — since
nothing about *it* needed to change; only what gates a parameter/return
type moved to the richer check.

### Passing/returning an aggregate by value: `llc` does the actual ABI work, this file just spells the type

Per the `v1.0.2` design doc's own bet (the reason the LLVM backend
landed before this step) — a composite parameter or return value is
just an ordinary value of aggregate LLVM type in the function
signature, the `call`, and the `ret`; `llc`'s own System V lowering
decides register-vs-hidden-pointer passing. Concretely, every place
that already spelled `i<W>` or `ptr` for a scalar/pointer parameter/
return gained a third branch that spells the composite's own type via
the existing `emit_composite_type`/`emit_struct_type_ref` helpers
instead — no new lowering logic, just a third type-spelling case
threaded through code that already had two.

### The recurring shape: "composite reg is always an address" meets a raw aggregate value at exactly two seams

Every composite `ExprResult`'s `reg` is an address (this file's
running invariant since the struct sub-pass) — but LLVM's own calling
convention hands aggregates around as raw *values* at the IR level
(`%argN` inside a callee, and a `call`'s own result register). The two
directions where that meets the address invariant:

- **A composite parameter, inside the callee**: `%argN` already *is*
  the incoming value (no address yet) — so `gen_function`'s param loop
  does exactly what it already does for a pointer parameter (alloca +
  one `store`), just storing the whole aggregate value instead of a
  scalar/pointer one. One `alloca <type>` + `store <type> %argN, ptr
  %vN` and the invariant holds again from that point on.
- **A composite argument, at the call site**: the reverse — the
  argument expression's own `ExprResult.reg` is an address (matching
  every other composite value in this file), but the `call` instruction
  needs the raw value, so one `load <type>, ptr %v<addr>` right before
  the call converts it. Symmetrically, **a composite return value** at
  the call site works the other way again: the `call`'s own result
  register holds the returned value directly, and gets materialized
  back into address form (one fresh `alloca` + `store`, the same
  pattern `gen_struct_lit`/`gen_array_lit_typed` already use for a
  literal's own temporary) so the call's result is an ordinary,
  invariant-respecting composite `ExprResult` like any other.

`gen_return_stmt`'s own composite branch is the same shape from the
*callee's* side: the return expression's address gets one `load`, and
the loaded value is `store`d into the return slot — structurally
identical to `emit_composite_copy` (the shared load+store helper every
other composite copy in this file already uses), except the
destination is the fixed name `%vret`, not a numbered `%v<N>` register,
so it's written out by hand rather than calling that helper directly.

### Shape-checked, not deeply type-checked — matching this file's existing rigor for composite copies

`gen_user_call`'s argument loop rejects a pointer/composite/scalar
*shape* mismatch against the callee's declared parameter (a struct
where a scalar is declared, or vice versa) with a clean codegen error.
It does **not** re-verify that a struct argument's own `struct_node`
exactly matches the declared parameter's struct identity beyond that
shape check — the same level of rigor `gen_assign_stmt`'s plain
composite-to-composite copy branch already has (unlike the broadcast-
init paths, which do check exact struct identity, because broadcast
was a *new* acceptance path with a real "different-shaped struct
silently accepted" risk this sub-pass didn't want to repeat). A
mismatched-but-same-shape struct argument was already an accepted gap
elsewhere in this file before this sub-pass; the calling convention
doesn't introduce a new one, just extends the existing one to a new
call site.

## Testing (sub-pass 5a, calling convention)

End-to-end (`llc`+`ld`+actually **run**), via `Stage1/tests/codegen_
cases/07_calling_convention.ptl`: a struct returned from one function
(`Point { x := x, y := y }` built from scalar parameters) and passed
*by value* into another, which mutates its own copy and returns it —
proving copy-isolation (the caller's original is untouched) the same
way the struct/array sub-passes' own copy tests did, but now across a
call boundary instead of a plain assignment; a composite-returning call
used directly as another call's *argument* (`shift(make_point(5, 6))`,
exercising the call-result-materialization path as an argument-loading
source in the same expression); and the array equivalent
(`int32[3]`-by-value, mutate-and-return, copy-isolation). Verified by
hand-computed and Docker-confirmed exit code (`238 mod 256 = 238`).
Also verified ad hoc: a `void`-returning function taking a struct
parameter by value (exercising the `fi.found && is_void` call-emission
path with a composite argument, not just the non-void path the main
fixture already covers), and a scalar argument passed where a struct
parameter is declared, cleanly rejected with `codegen error` rather
than silently mishandled.

### A known, deliberately out-of-scope gap: `f().field` / `Literal{}.field`

Field or index access directly on a function-call result or a bare
struct/array literal, with no intermediate variable, does **not** work
— `gen_lvalue`'s `AST_EX_FIELD`/`AST_EX_INDEX` cases recurse into their
own base via `gen_lvalue(base)`, which only handles lvalue-shaped node
kinds (`AST_EX_IDENT`, a pointer deref, `AST_EX_FIELD`, `AST_EX_INDEX`
themselves) — a call (`AST_EX_CALL`) or a literal is a genuine rvalue,
so `gen_lvalue` fails cleanly on it rather than silently misreading it.
This is a pre-existing property of `gen_lvalue`'s own design, not
something this sub-pass introduced or was expected to fix — every
composite value this sub-pass produces (including a call's own
materialized return value) is still address-shaped and *could* in
principle support this by having `gen_lvalue` fall back to `gen_expr`
for a non-lvalue composite base, but that's a small, separate follow-up
rather than part of "structs/arrays pass through calls correctly."
Write `const tmp := f(); tmp.field;` instead, for now.

## Sub-pass 5b: composite pointees

Not yet implemented — see this document's "Scope" section above. Will
be written up here once landed: struct/array-typed pointers, removing
the scalar-only restriction `type_ok_local`'s pointer branch currently
imposes on the pointee (`*Point`, `*int32[3]`).
