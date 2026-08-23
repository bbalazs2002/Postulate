# Stage 1

The self-hosting successor to Hoare (Stage 0): a Postulate compiler
written **in Postulate itself** — specifically, in the v0 language
Hoare (the hand-written x86_64 NASM Stage 0 compiler) already defines,
so that Hoare can compile Stage 1's own source. Once Stage 1 can
compile itself, Stage 0 becomes historical/discardable — see the
project's bootstrap plan.

Stage 1 does **not** implement v1 (the language design worked out in
`docs/postulate_v1_language_reference.md`) — it targets exactly v0,
the same language Hoare already compiles. Extending Stage 1 to v1 is
future work, after self-hosting is achieved.

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
| Lexer | `src/lexer.ptl` | Done — reads a v0 program from stdin, writes Hoare's own token-dump format to stdout, matches Hoare's own diagnostics (message text, line/col, exit codes) exactly. Verified against `Hoare/tests/cases/*` unchanged: all 7 fixtures pass byte-for-byte. |
| Parser | `src/parser.ptl` | Done — reads a v0 program from stdin, parses it as `program` (chapter 6 of the parser spec), dumps the resulting AST (a flat `<id> <kind> <a> <b> <c> <d>` listing, not Hoare's own s-expression format — see the file header) or a syntax diagnostic with line/col. Verified against `Hoare/tests/codegen_cases/*` (30 known-valid, composite-heavy programs — all parse), `Hoare/tests/checker_cases/*` (68 syntactically-valid programs — all parse, regardless of whether Hoare's checker itself would accept them semantically), and `Hoare/tests/blackbox_cases/*` (24 programs, `PROGRAM` directive line stripped — the 12 `_valid` ones parse, the 12 `_error` ones are correctly rejected, each for a genuine syntax defect — missing `;`, mismatched `(` — confirmed by inspection, not assumed). |
| Codegen | (next) | Not started. |

### Two bugs this phase found in Hoare itself

Bootstrapping this lexer exercised a code path Hoare's own test suite
never had: a composite-returning function call as the right-hand side
of a **plain assignment** to an already-declared local (`p := f();`),
as opposed to a decl-initializer (`mut p: T := f();`). That crashed —
see `docs/postulate_stage0_codegen_spec.md` §9a and the commit that
fixed it in `Hoare/src/codegen_stmt.asm` for the full story.

Bootstrapping the parser found a second, broader one: a composite
argument sourced from a call or a struct/array literal, in any
parameter position except the last, corrupts every other argument the
callee reads — see §9b of the same spec for the full mechanism and a
minimal repro. This one was **documented, not fixed** — the real fix
touches `gen_user_call`'s argument-reservation scheme in a few
interconnected places, a bigger and riskier change than §9a's one-line
reorder, and `parser.ptl` has a clean, verified-safe workaround (bind
the composite value to a named local before passing it alongside other
arguments) — see the file's own header comment for the exact rule.
Both are reminders that self-hosting is also a genuine correctness
exercise for Stage 0, not just a milestone for Stage 1.

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
