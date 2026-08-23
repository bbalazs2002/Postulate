# Stage 1

The self-hosting successor to Hoare (Stage 0): a Postulate compiler
written **in Postulate itself** — specifically, in the v0 language
Hoare (the hand-written x86_64 NASM Stage 0 compiler) already defines,
so that Hoare can compile Stage 1's own source. Once Stage 1 can
compile itself, Stage 0 becomes historical/discardable — see
[the project's bootstrap plan](../docs/postulate_stage1_bootstrap_plan.md).

Stage 1 does **not** implement v1 (the language design worked out in
`docs/postulate_v1_language_reference.md`) — it targets exactly v0,
the same language Hoare already compiles. Extending Stage 1 to v1 is
future work, after self-hosting is achieved.

**One narrow, deliberate exception, starting `v1.0.2`:** function-call
argument evaluation order follows v1's left-to-right rule, not v0's
right-to-left one — the only place Stage 1 currently deviates from
"targets exactly v0." See
[`docs/postulate_stage1_v1_0_2_llvm_backend_design.md`](../docs/postulate_stage1_v1_0_2_llvm_backend_design.md)
for why (short version: v0's right-to-left order was a byproduct of
the NASM backend's push-based calling convention, which the LLVM IR
backend removes). This is not a precedent for pulling in other v1
features early — the next deliberate one is statement sugar at
`v1.0.7`.

## Why everything here looks the way it does

v0 has real, load-bearing constraints that shaped every file in this
directory — worth knowing before reading the source:

- **No `#include`, no separate compilation.** v0 has no way to import
  one file's declarations into another (that's a v1 feature). Every
  standalone Stage 1 binary is therefore a single, self-contained
  `.ptl` file that duplicates whatever it needs from earlier phases
  (e.g. the parser's own copy of the tokenizer) — there is no way to
  factor shared logic into a library Hoare could link separately, the
  way Hoare's own `lexer.o` is shared across its `lexer`/`parser`/
  `checker`/`codegen` binaries.
- **No command-line argument access.** `main()` always takes zero
  parameters in v0. Every Stage 1 binary is a stdin → stdout filter,
  exactly like Hoare's own `build/codegen` (`./hoare` itself pipes a
  `.ptl` file into it: `codegen < input.ptl > output.asm`).
- **No cast operator, no implicit conversion.** Moving a value between
  two different integer types (e.g. a syscall's `int64` return value
  into a `uint64` running total) has no built-in conversion — see
  `int64_to_uint64` in `src/lexer.ptl` for the unary-counting bridge
  used throughout this directory, and `digit_to_ascii`/`nibble_to_hex`
  for the small-range comparison-chain version of the same idea.
- **All declarations must be at the very top of a function body** — a
  `while`/`if` block permits no `decl`s at all (`block ::= "{" stmt*
  "}"`, distinct from `func_block`). Every local a function will ever
  need is declared once, up front, then only assigned to afterward.
- **No pointer arithmetic, no heap-indexable buffers without a cast.**
  A `sys_mmap` result is a bare `*uint8` — useless for indexing without
  a conversion this language doesn't have. Buffers are therefore
  fixed-size **stack-local arrays** (`uint8[N]`, `N` a literal — array
  sizes can't be parameterized either), passed to helper functions as
  `*(uint8[N])` (pointer-to-whole-array, §2.5 of the v0 reference) and
  indexed through with `(*buf)[i]`, never walked with pointer math.
- **No string literals.** Every fixed piece of output text (token dump
  labels, error-message text) is a byte array, generated once from the
  real string with a small Python script (not hand-transcribed — see
  the git history for `src/lexer.ptl` if you need the generator) and
  spliced in as a `const`/`mut` array literal.
- **No heap-allocated, pointer-linked tree.** `sys_mmap` only ever
  returns `*uint8` (no cast to reinterpret it as anything else), and a
  stack-local `Node[N]` array can't be declared either (a struct-typed
  array's mandatory initializer would have to enumerate all N elements
  by hand). The parser's AST is therefore an **index-based arena**:
  Hoare's own `(kind, a, b, c, d)` node shape (docs/postulate_stage0_
  parser_spec.md §4), stored as five parallel scalar arrays indexed by
  a plain `uint64` "node id" instead of a `*Node` — see `parser.ptl`'s
  own header comment for the full design and the node-kind/field table.
- **A composite argument sourced from a call or literal, in any
  position but the last, corrupts every other argument** — a second
  Hoare codegen bug this phase found, documented but *not* fixed (see
  below) — so `parser.ptl` never inlines `advance(st)`-style calls as
  a non-last argument; it always binds to a plain local first. See its
  header comment for the exact rule.

## Phases

| Phase | File | Status |
|---|---|---|
| Lexer | `src/lexer.ptl` | Done, now including `v1.0.1`'s `#include` — reads a program from stdin (the entry file), resolves every `#include` transitively via a three-phase discover/order/emit pass (`docs/postulate_stage1_v1_0_1_include_design.md`) before tokenizing the merged result, writes Hoare's own token-dump format to stdout, matches Hoare's own diagnostics (message text, line/col, exit codes) exactly for the zero-`#include` case, and gains a filename once more than one file is involved. Verified against `Hoare/tests/cases/*` unchanged (all 7 fixtures pass byte-for-byte) plus `Stage1/tests/include_cases/*` (16 fixtures: ordering, diamond dedup, cycle detection, nested relative paths, malformed/reserved forms, preamble rules, comment-safety, multi-directive-per-line, and diagnostic file/line/byte-offset correctness at various nesting depths) — run via `BINARY_KIND=lexer Stage1/tests/run_include_tests.sh`. `sys_openat`/`sys_close` (Linux 257/3) were added to Hoare's own extern whitelist to unblock this (`docs/postulate_v0_language_reference.md` §5.2). |
| Parser | `src/parser.ptl` | Done, `#include` included — the same `resolve_includes` pass (byte-for-byte identical source to the lexer's copy, per the design doc's "tripled" duplication) ported over; diagnostics gain a filename the same way, using the parser's own wording ("parse error at token N in file '...'"). Verified against everything it always was (`Hoare/tests/codegen_cases/*`, `Hoare/tests/checker_cases/*`, `Hoare/tests/blackbox_cases/*` — 100+24 programs, `PROGRAM` line stripped) plus the same 16 `include_cases` fixtures (`BINARY_KIND=parser Stage1/tests/run_include_tests.sh` — exit codes only; parser diagnostics have their own wording, not compared byte-for-byte against the lexer's). |
| Codegen | `src/codegen.ptl` | Done, `#include` included, on the `v1.0.2` LLVM IR backend (`docs/postulate_stage1_v1_0_2_llvm_backend_design.md`), through `v1.0.3`'s width-unification, struct, array, pointer (scalar-pointee), and now also the **calling convention** sub-passes (`docs/postulate_stage1_v1_0_3_composites_design.md`) — struct-typed locals, field read/write (nested chains included), struct literals (nested included), struct-to-struct copy; array-typed locals, index read/write (chained index+field lvalues like `pts[1].x` included), array literals (array-of-struct included), broadcast-init (scalar *or* struct source, both at decl-init and at assignment), array-to-array copy; `&`/`*`, `null`, pointer-typed locals/parameters/return values, `==`/`!=` pointer comparison, restricted to a scalar pointee (`*int32`, not `*Point`/`*int32[3]`/`**int32`); and now **struct/array-typed parameters and return values, passed/returned by value with full independent-copy semantics** (`type_ok`'s scalar-only restriction removed for parameters/return values, `llc`'s own ABI lowering does the actual register-vs-memory work) — via LLVM's native packed struct types (`%struct.Name = type <{ ... }>`, zero padding, matching v0 §2.6 exactly), native array types (`[N x T]`), opaque `ptr` for pointers, and a real `gen_lvalue`. Pointers with a **composite pointee are still deliberately out of scope** (rejected with `codegen error`); so is direct field/index access on a bare call result or literal with no intermediate variable (`f().field`) — a pre-existing property of `gen_lvalue`'s own lvalue-only recursion, not something this sub-pass fixed. Also carries `v1.0.2`'s one deliberate, documented exception: function-call argument evaluation order is **left to right** (v1's rule), not v0's right-to-left. Verified end-to-end (lowered with `llc -filetype=obj`, linked with `ld`, actually **run**) against every scalar-only-compatible fixture in `Hoare/tests/codegen_cases/*` (`01`–`10`, `19`, `20`), the 16 `include_cases` fixtures, and `Stage1/tests/codegen_cases/*` (eval-order, narrow-type wraparound, struct field/literal/copy-isolation, array index/literal/broadcast-init/copy-isolation, struct-source/assignment-time broadcast-init with its own copy-isolation and mismatch-rejection checks, pointer round-trip/null-comparison/param-and-return-value tests, and struct/array parameters+return values with copy-isolation and call-chaining — see each fixture's own header comment). |

### Two bugs this phase found in Hoare itself

Bootstrapping this lexer exercised a code path Hoare's own test suite
never had: a composite-returning function call as the right-hand side
of a **plain assignment** to an already-declared local (`p := f();`),
as opposed to a decl-initializer (`mut p: T := f();`). That crashed —
see `docs/postulate_stage0_codegen_spec.md` §9a and the commit that
fixed it in `Hoare/src/codegen_stmt.asm` for the full story.

Bootstrapping the parser found a second, broader one: a composite
argument sourced from a call or a struct/array literal, in any
parameter position except the last, corrupted every other argument the
callee read — see §9b of the same spec for the full mechanism, the fix
(`gen_user_call` now reserves one combined temp block for every
composite argument upfront, at fixed offsets, instead of each one
`sub rsp`-ing for itself mid-loop), and its own regression fixtures
(`Hoare/tests/codegen_cases/31`–`32`). Originally shipped as
**documented, not fixed**, with `parser.ptl` routing around it (bind
the composite value to a named local before passing it alongside other
arguments — see the file's own header comment); that workaround is no
longer strictly required now that the underlying bug is fixed, but was
left in place since there was no reason to change already-working code
just because the constraint it existed for is gone.
Both are reminders that self-hosting is also a genuine correctness
exercise for Stage 0, not just a milestone for Stage 1.

### Three bugs this phase found in Stage 1's own code

None of these are Hoare bugs — Stage 0 compiled every one of these
programs exactly as written. They're logic mistakes in `parser.ptl`/
`codegen.ptl` themselves, caught only once codegen output was actually
assembled, linked, and *run* (not just "did it compile"):

- **List-pool contiguity.** Every `(start, count)` list this arena
  builds (call args, struct fields, decls, statements, params, top-
  level decls, simultaneous-assignment pairs) was originally built by
  "capture `start`, then append each item right after parsing it" —
  which silently breaks the moment an item's own parsing does list
  appends of its own (a nested call's args, a nested function's own
  decls/statements), landing between this list's own entries. A
  two-function program's second function ended up reading a stray
  internal node id instead of its own. Fixed by staging item ids into
  a local `uint64[256]` array while parsing, then bulk-appending them
  to `list_pool` in one uninterrupted pass once parsing for that list
  is complete — see any of the affected functions' own comments (e.g.
  `parse_expr_list`) for the exact shape.
- **A leftover instance of the "composite-in-non-last-position" Hoare
  bug (§9b above) in Stage 1's own code**, despite the workaround rule
  being documented and followed everywhere else: `parse_unary`
  called `alloc_node(bufs, result_state(inner), 14, ...)`, passing a
  freshly-computed `PState` (a call result, not a plain local) as the
  *second* of seven arguments — corrupting the sibling arguments in
  exactly the way `parse_primary`'s own header comment warns against.
  In `codegen.ptl`, the same anti-pattern in `gen_expr`'s binary-
  operator case, `gen_binop`, `gen_and`, and `gen_or` (a `GState { ... }`
  literal built inline as a non-last call argument) corrupted `bufs`
  itself, making every binary expression (`+`, `%`, `==`, …) fail with
  a generic `codegen error`. Fixed the same way throughout: bind the
  composite to an existing local first, then pass that local.
- **`pop rbx` instead of `pop rax`** in `gen_expr`'s binary-operator
  case — after evaluating the right operand and copying it into `rbx`,
  the left operand (pushed earlier) needs popping back into `rax`; the
  wrong emit-piece id was used, so `rbx` ended up holding the *left*
  operand and `rax` still held the *right* one, silently swapping every
  binary operator's operands (caught by `n % 2` returning the divisor
  instead of the remainder). And `gen_or`'s short-circuit branch had
  its `je`-target and fall-through swapped relative to what OR actually
  needs (mirrored from `gen_and` without inverting the roles), making
  `a || b` return `b`'s value when `a` is true instead of short-
  circuiting to `true` — caught by `true || false` returning `false`.

## Building and testing

No Dockerfile of its own yet (small enough to drive by hand so far).
From the repository root, using Hoare's own image or an equivalent
Linux toolchain (`nasm`, `binutils`):

```sh
cd Hoare
./hoare ../Stage1/src/lexer.ptl -o /tmp/stage1_lexer

for f in tests/cases/*.ptl; do
  base="${f%.ptl}"
  /tmp/stage1_lexer < "$f" > /tmp/out 2> /tmp/err
  diff "$base.expected.stdout" /tmp/out
  diff "$base.expected.stderr" /tmp/err
  [ "$?" -eq "$(cat "$base.expected.exit")" ] || echo "exit mismatch: $base"
done
```

The parser has no matching fixture format of its own (its dump is a
flat listing, not Hoare's s-expression form, see the phase table
above) — smoke-test it against any known-valid whole-program `.ptl`
file instead, checking only the exit code:

```sh
./hoare ../Stage1/src/parser.ptl -o /tmp/stage1_parser
/tmp/stage1_parser < tests/codegen_cases/24_composite_return.ptl
echo $?   # 0 == parsed; the AST dump itself goes to stdout
```

The codegen phase can be driven all the way to a running binary, since
its output is LLVM IR (`v1.0.2` — see
[`docs/postulate_stage1_v1_0_2_llvm_backend_design.md`](../docs/postulate_stage1_v1_0_2_llvm_backend_design.md);
`llc` and `opt` ship in Ubuntu's `llvm` package, alongside `nasm`/
`binutils` in `Hoare/Dockerfile`):

```sh
./hoare ../Stage1/src/codegen.ptl -o /tmp/stage1_codegen
/tmp/stage1_codegen < tests/codegen_cases/20_recursion_factorial.ptl > /tmp/out.ll
llc -filetype=obj -mtriple=x86_64-unknown-linux-gnu -o /tmp/out.o /tmp/out.ll
ld -static -no-pie -e _start -o /tmp/out /tmp/out.o
/tmp/out; echo $?   # 120
```
