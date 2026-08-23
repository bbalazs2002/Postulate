# `v1.0.2` design: LLVM IR codegen backend

## Scope

This is the implementation design for step `v1.0.2` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md): switch
`Stage1/src/codegen.ptl`'s output from x86-64 NASM assembly text to
LLVM IR text, lowered by `llc` instead of assembled by `nasm`. Same
scalar-only feature set as today (`int8`‥`int64`, `uint8`‥`uint64`,
`bool`) — a backend swap, not a feature addition. Composite
(struct/array) parameters/returns stay out of scope here; they land in
`v1.0.3`, built directly on LLVM's native aggregate types (§2 of the
bootstrap plan explains why that ordering — doing struct-by-value
passing once, against LLVM's own lowering, rather than by hand in NASM
first and redoing it for LLVM immediately after).

Only the codegen-proper section of `codegen.ptl` changes: `emit_piece`,
the `gen_*` functions, and `main()`'s driver tail. The file's own
duplicated lexer, parser, and `#include`-resolution sections are
untouched — they produce the same AST this phase already consumes
today; nothing about `v1.0.1` is affected by this step.

## Why this is not a mechanical text-format swap

It would be possible to keep every existing design decision in
`codegen.ptl` (the custom push-based calling convention, `rbp`-relative
addressing, one x86 mnemonic ↔ one LLVM instruction) and just change
the *spelling* of each emitted fragment. That would be a mistake: it
would require hand-implementing register allocation, stack-slot
addressing, and calling-convention lowering entirely in Postulate code
a second time — exactly the "fiddly, error-prone" work real backends
exist to solve, and exactly what the bootstrap plan (§2, point 3)
identifies as the actual payoff of this step. The design below instead
generates the kind of unoptimized-but-idiomatic IR `clang -O0` itself
produces: one `alloca` per local, real typed function signatures, and
ordinary `call`/`br`/`ret` instructions — deliberately **not** SSA-form
reasoning (see "Locals" below), and deliberately letting `llc` own
every decision that used to be hand-rolled: which register a value
lives in, how the stack frame is laid out, how arguments physically
cross a call boundary, whether `rsp` is 16-aligned at each `call`.

## Type mapping

Direct, 1:1, no surprises:

| Postulate | LLVM IR |
|---|---|
| `int8` / `uint8` | `i8` |
| `int16` / `uint16` | `i16` |
| `int32` / `uint32` | `i32` |
| `int64` / `uint64` | `i64` |
| `bool` | `i1` |

Signedness is not a distinct LLVM type (LLVM integers are sign-agnostic
bit patterns) — it only affects which *instruction* is chosen:
`sdiv`/`udiv`, `srem`/`urem`, `icmp slt`/`icmp ult` (and the other three
signed/unsigned comparison pairs), and any width-changing cast (not
reachable yet — v0 has no implicit conversion and `as` doesn't exist
until `v1.0.8`). `codegen.ptl` already computes signedness per-value
today (`type_is_signed`, existing helper) — reused unchanged; only the
instruction mnemonic it selects between changes.

## Locals: `alloca`, not SSA registers

Every `decl` and every parameter gets one `alloca` in the function's
entry block, sized to its type from the table above. Every read of a
local is a fresh `load`; every assignment is a `store`. This is the
standard `-O0` technique (also called out directly in the bootstrap
plan, §2's implementation notes) and is deliberate: it sidesteps SSA
form entirely — codegen.ptl never has to compute dominance, insert
`phi` nodes, or reason about which definition of a variable reaches
which use. `opt`'s `mem2reg` pass (turned on in `v1.0.5`, not before)
promotes these `alloca`s to real SSA registers automatically as a
later, separate concern.

The existing `SymInfo`/`sym_find`/`sym_add` local table (`GBufs`,
today: parallel arrays of name/offset/signed) carries over structurally
unchanged — `offset: uint64` (an `rbp`-relative byte offset) becomes
`reg: uint64` (the `%N` register number the local's `alloca`
instruction was assigned), same linear-scan lookup, same call sites.

## Value numbering

A monotonic per-function counter (`GState.next_value`, sibling to the
existing `next_label`) assigns every `alloca`, every `load`, every
computed intermediate, and every `call` result its own `%N`. Every
`gen_expr`-family function's signature changes from "the result ends
up in `rax`" to "returns the `%N` that holds the result," threaded
explicitly as a return value — the same shape change `gen_lvalue`
already uses today for "return an address," just generalized to every
expression, not only lvalues.

## Control flow

`if`/`while` become real basic blocks. The existing label-numbering
scheme (`GState.next_label`, today producing `.Lelse<N>`/`.Lend<N>`/
`.Lwhile<N>`/`.Lwend<N>`) is reused verbatim as LLVM basic-block labels
— only the instructions inside each block change:

```llvm
; if (cond) { then_body } else { else_body }
  %c1 = ...                      ; cond, evaluated into %c1 (i1)
  br i1 %c1, label %then1, label %else1
then1:
  ...                            ; then_body
  br label %end1
else1:
  ...                            ; else_body
  br label %end1
end1:
```

```llvm
; while (cond) { body }
  br label %while2
while2:
  %c2 = ...                      ; cond
  br i1 %c2, label %wbody2, label %wend2
wbody2:
  ...                            ; body
  br label %while2
wend2:
```

`&&`/`||` short-circuit via the same `alloca`-backed-temporary
technique as ordinary locals — deliberately **not** a `phi` node, to
keep every value-producing construct in the file using the same one
mechanism (alloca/load/store) rather than two:

```llvm
; a && b
  %r3 = alloca i1
  %a3 = ...                      ; a
  br i1 %a3, label %and_rhs3, label %and_short3
and_rhs3:
  %b3 = ...                      ; b, only evaluated if a was true
  store i1 %b3, ptr %r3
  br label %and_end3
and_short3:
  store i1 false, ptr %r3
  br label %and_end3
and_end3:
  %v3 = load i1, ptr %r3
```

`||` mirrors this with the branch condition and the short-circuit
stored value inverted (`a` true → short-circuit to `true` without
evaluating `b`).

## Function calls

LLVM's ordinary typed `call` instruction — `%r = call i64
@pf_add(i64 %a, i64 %b)` — replaces the entire push-based argument
convention documented in today's file header (right-to-left
evaluation, immediate `push` per argument, callee reading
`[rbp+16+i*8]`). `llc` owns argument-register assignment, stack
alignment at the call site, and the call itself via its normal System V
AMD64 lowering; `gen_user_call` shrinks to "evaluate each argument to a
value, then emit one `call` instruction naming them all."

**Argument evaluation order changes from right-to-left to
left-to-right — a v1 language decision, made as part of this step, not
an incidental side effect of it.** v0's right-to-left rule
([`postulate_v0_language_reference.md` §3.9](postulate_v0_language_reference.md),
"deliberate, specified behavior... applies uniformly to both `extern
function` calls and ordinary user function calls") exists because it
was the natural order for the push-based convention above (arg1,
evaluated last, ends up closest to `rsp`) — the order was a consequence
of the mechanism, not a free-standing design goal in its own right.
That mechanism is exactly what this step removes: nothing about `llc`'s
own argument lowering depends on, or benefits from, any particular
*source-level* evaluation order — it consumes already-computed values
uniformly regardless of which one was computed first. With the
mechanical reason gone, `v1` — the language Stage 1 actually exists to
build (`Stage1/README.md`: Stage 1 "does not implement `v1`... yet,"
not "must replicate every `v0` behavioral choice forever") — adopts
left-to-right instead, matching source reading order, which every
language in the C-family tradition without a specific reason to do
otherwise defaults to. It remains a *fixed, specified* order, never
"unspecified" the way C leaves it: that non-negotiable principle
(`postulate_v0_language_reference.md` §1, "evaluation order is always
fixed and documented rather than left [unspecified]") carries over to
`v1` unchanged — only *which* order is fixed changes.

Concretely, for `f(a(), b())`: `a()` is now evaluated (its `call`
instruction emitted) before `b()`'s, before `f`'s own `call` is built.
`v0`/Hoare are **not** touched — they keep right-to-left, frozen,
exactly as documented (Hoare becomes historical once Stage 1
self-hosts, per the bootstrap plan's closing section; there is no
plan to ever reconcile the two).

Two documents need updating alongside the code, not after it:

- [`postulate_v1_language_reference.md`](postulate_v1_language_reference.md)
  §3.9 currently reads "Unchanged from v0... right-to-left argument
  evaluation." This becomes **Changed**: left-to-right, with a
  one-sentence pointer back to this design doc for the rationale.
  [`postulate_v0_language_reference.md`](postulate_v0_language_reference.md)
  §3.9 itself is **not** edited — it continues to correctly describe
  what Hoare and the `v0`-era Stage 1 proof of concept actually
  implement.
- `Stage1/README.md`'s "why everything here looks the way it does"
  intro states Stage 1 "targets exactly v0." From `v1.0.2` onward that
  needs one narrow, explicitly named exception for evaluation order —
  not a silent drift from what the intro promises, and not a precedent
  for casually pulling in other `v1` features ahead of their own step
  (the next deliberate `v1`-feature step is `v1.0.7`).

## `extern function` calls and `_start`

LLVM IR has no portable syscall intrinsic, so the five whitelisted
externs (`sys_read`=0, `sys_write`=1, `sys_close`=3, `sys_exit`=60,
`sys_openat`=257 — standard Linux x86-64 numbers, already in use today)
are each emitted as a `call` to an inline-asm blob with
register-constrained operands — the standard LLVM idiom for raw
syscalls (used by e.g. Rust's and Zig's own freestanding raw-syscall
paths), and the only realistic option short of linking a separate
hand-written stub object:

```llvm
; sys_write(fd, buf, count) -> i64
%ret = call i64 asm sideeffect
  "syscall",
  "={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
  (i64 1, i64 %fd, i64 %buf, i64 %count)
```

(`1` is `sys_write`'s syscall number, loaded into the `rax` input
constraint directly as an immediate — `rax` is both an input, the
syscall number, and the output constraint, the return value, matching
the real `syscall` instruction's own behavior.) `rcx`/`r11` are marked
clobbered because the `syscall` instruction itself overwrites them
(architectural fact, not a convention choice); `~{memory}` prevents
`llc` from reordering surrounding memory operations across the call.

`_start` becomes a plain `define void @_start()`: calls `@pf_main`,
then performs the exit syscall inline-asm above with `main`'s return
value (or `0` for a `void` main, exactly like today's
`main_returns_value` dispatch), then `unreachable`. No `@main`/libc/
crt0 convention — this preserves today's `-static -no-pie -e _start`,
no-libc link line exactly. `_start` never reaches a `ret` (the process
exits via the syscall, not by returning), so any prologue `llc` may
still emit for it is dead code that never executes — harmless, not
worth suppressing.

## `emit_piece`: same pattern, new contents

The existing fixed-template-text dispatch (`append_str`-driven, one
byte-array constant per fragment, `emit_piece(out, pos, piece_id)`)
carries over unchanged as a mechanism — it already works, and nothing
about switching target languages makes it a worse fit. Only the ~150
case bodies change from x86 mnemonic fragments (`"  mov [rbp - "`) to
LLVM IR text fragments (`"  %"`, `" = alloca i"`, `" = load i"`,
`" = call i64 @pf_"`, ...). A `gen_*` function now typically emits:
piece (opening text) → `append_uint` (a `%N` register number or a
type's bit width) → piece (separator) → `append_uint`/recursive
`gen_expr` call (an operand) → piece (closing text) — structurally the
same three-part concatenation pattern used throughout the file today,
just assembling LLVM syntax instead of x86 syntax.

## Emitted `.ll` stays minimal

No `target datalayout`/`target triple` lines in the generated text —
`llc` is invoked with `-mtriple=x86_64-unknown-linux-gnu` on the
command line instead. This keeps the emitted IR independent of the
exact datalayout string a particular LLVM version expects, and keeps
`codegen.ptl` itself free of a magic constant that would silently go
stale across an LLVM upgrade.

## Toolchain

- `Hoare/Dockerfile` (and `Dockerfile.release`, if it needs to run
  Stage1-produced binaries): add `llvm` to the existing `apt-get
  install -y --no-install-recommends nasm binutils bash ...` line —
  `llc` and `opt` both ship inside Ubuntu 24.04's `llvm` package, no
  new base image required.
- Pipeline: `llc -filetype=obj -mtriple=x86_64-unknown-linux-gnu -o
  out.o out.ll`, then the **exact same** `ld -static -no-pie -e _start
  -o out out.o` as today — `llc -filetype=obj` emits a standard ELF
  object directly, so nothing downstream of assembly changes.
- `Hoare/scripts/run_codegen_tests.sh` and `Stage1/README.md`'s
  documented pipeline both get their `nasm -f elf64 ...` line replaced
  with the `llc` invocation above; the `ld` line is untouched.

## Testing

Same bar the bootstrap plan sets for this step: "verified against the
exact fixture suite the NASM backend already passes, proving the swap
changes nothing observable yet" — except for the one deliberate,
called-out exception (evaluation order), which gets its own new,
positive fixture rather than being lumped in with "everything else
still matches."

- All scalar-only `Hoare/tests/codegen_cases/*` (`01`–`10`, `19`, `20`):
  assemble via `llc`, link via `ld` (unchanged), run, compare exit
  codes/stdout against the NASM backend's own results.
- All 16 `Stage1/tests/include_cases/*` fixtures, `BINARY_KIND=codegen`.
- A new fixture with side-effecting call arguments, e.g. `f(g(), h())`
  where `g`/`h` each perform a distinguishable `sys_write`, whose
  expected output is authored against the new left-to-right order.
- No existing test diffs raw NASM text byte-for-byte (only the final
  linked binary's exit code/stdout are checked, confirmed via
  `Stage1/README.md`'s testing section) — so nothing here needs a
  "golden `.ll` file" comparison; behavioral equivalence is the whole
  bar.
- Full `docker build` on `Hoare/Dockerfile` once `llvm` is added,
  confirming the rest of Hoare (Stage 0, untouched by this step) still
  builds.

## Explicitly out of scope

- Composite (struct/array) parameters/returns — `v1.0.3`, built on
  LLVM's native aggregate types once this step's plumbing exists.
- Separate compilation, multiple `.ll` modules — `v1.0.4`.
- Running anything through `opt` — `v1.0.5`. This step's IR is
  deliberately unoptimized `-O0`-shaped output; no `mem2reg`, no
  constant folding, nothing beyond what `llc` does on its own.
- Any other `v1` surface (statement sugar, `char`, floats, pointer
  arithmetic, `ref`, contracts, ...) — all later steps, per the
  bootstrap plan's step list. The evaluation-order change above is a
  narrow, explicitly justified exception to "no other `v1` features
  land before `v1.0.7`," not a precedent for pulling more forward.
