# Hoare — the Postulate Stage 0 bootstrap compiler

Four standalone, Docker-built, Docker-tested x86_64 NASM binaries — this
directory *is* the Stage 0 compiler, named **Hoare** — plus the unified
**`./hoare`** CLI (see "Compiling a program" below) that wraps them all
into one command:

- **`build/lexer`** — reads a Postulate source file on stdin, writes a text
  token dump to stdout. See
  [docs/postulate_stage0_lexer_spec.md](../docs/postulate_stage0_lexer_spec.md).
- **`build/parser`** — reads a directive-prefixed snippet on stdin (`TYPE`,
  `EXPR`, `DECL`, `STMT`, `FUNC_BLOCK`, `TOP_LEVEL_DECL`, or `PROGRAM`, see
  below), parses it as the corresponding grammar rule, and writes an
  S-expression AST dump to stdout. Covers the **entire** Stage 0 EBNF, from
  the top-level `program` rule down to the deepest expression level —
  `function`/`struct`/`extern` declarations and `params` included.
  See [docs/postulate_stage0_parser_spec.md](../docs/postulate_stage0_parser_spec.md).
- **`build/checker`** — reads a whole `.ptl` file on stdin (no directive
  line — checking is always whole-program), parses it, then runs name
  resolution and full type checking over it, writing `OK` to stdout on
  success. See
  [docs/postulate_stage0_semantics_spec.md](../docs/postulate_stage0_semantics_spec.md)
  for exactly what's covered.
- **`build/codegen`** — reads a whole `.ptl` file on stdin, parses and
  checks it (same pipeline as `build/checker`), then emits NASM assembly
  text to stdout for the whole program — structs, arrays, pointers,
  arbitrarily many functions (with recursion), and struct/array values
  crossing function-call boundaries as arguments or return values. See
  [docs/postulate_stage0_codegen_spec.md](../docs/postulate_stage0_codegen_spec.md).

## Build and test

```powershell
docker build -t postulate-hoare Hoare
```

This is the single, complete pass/fail gate: it assembles all four
binaries (`scripts/build.sh`) and runs six fixture suites as build
steps — a failing test fails the build:

- `scripts/run_tests.sh` — lexer fixtures (`tests/cases/`).
- `scripts/run_parser_tests.sh` — **white-box** parser fixtures
  (`tests/parser_cases/`), each scoped to a single grammar rule via a
  directive.
- `scripts/run_blackbox_tests.sh` — **black-box** parser fixtures
  (`tests/blackbox_cases/`), each a complete, realistic `PROGRAM` (classic
  textbook algorithm implementations and combinations, plus one
  compiler-scale multi-declaration program), checked only by observable
  behavior (exit code / stdout / stderr) — see the parser spec section 16.
- `scripts/run_checker_tests.sh` — semantic-checker fixtures
  (`tests/checker_cases/`), one correct/incorrect pair per rule — see the
  semantics spec section 9. (The 12 `*_valid` black-box programs above are
  also re-verified against `build/checker` as part of that phase's
  verification, though not as a separate scripted suite.)
- `scripts/run_codegen_tests.sh` — code-generator fixtures
  (`tests/codegen_cases/`): the generated assembly is actually assembled
  (`nasm`), linked (`ld`), **executed**, and its real exit code (and
  stdout, where checked) compared against the fixture's expected values —
  see the codegen spec section 8.
- `scripts/run_stack_check_tests.sh` — debug-only stack-corruption
  instrumentation (`POSTULATE_STACK_CHECK=1`, see "Stack-corruption
  self-check" below): a handful of hand-written NASM sanity fixtures
  (`tests/stack_check_cases/`) proving the detector itself fires, plus
  the entire `tests/codegen_cases/` suite recompiled with the flag on and
  re-executed, proving none of the real, working test programs leave any
  stack corruption behind.
- `scripts/run_hoare_cli_tests.sh` — smoke-tests the `./hoare` CLI itself
  (see "Compiling a program" below): a successful compile-and-run, the
  same with `--stack-trace`, a codegen-rejected input's exit code
  propagating correctly without attempting to assemble/link garbage, and
  basic usage-error handling.

## Compiling a program

`./hoare` is the single command that replaces the four-stage manual
pipeline (`build/codegen` → `nasm` → `ld`) end to end — it parses,
checks, generates, assembles, and links one `.ptl` file into a runnable
ELF binary:

```bash
./hoare test.ptl              # -> ./test
./test
```

```
usage: hoare <file.ptl> [-o <output>] [--stack-trace]
  -o <output>     output binary path (default: <file> with .ptl stripped)
  --stack-trace   compile with the debug-only stack-corruption self-check
                  (POSTULATE_STACK_CHECK=1 -- see "Stack-corruption self-check")
```

It needs `nasm`/`ld` on `PATH` and `build/codegen` already built (same
requirement as every script above) — run it from inside the Docker image
or an equivalent Linux toolchain, not directly on a Windows host. From a
Windows host via Docker, bind-mount your working directory in and run it
there:

```powershell
docker run --rm -v ${PWD}:/work -w /work --entrypoint /workspace/hoare postulate-hoare /work/test.ptl
```

**`hoare`'s own exit codes** (distinct from `build/codegen`'s 0-4 and the
runtime self-check's 112/113 below — these three only ever come from the
wrapper script itself, before or after the underlying binaries run):

| Code | Meaning |
|---|---|
| `5` | `nasm` rejected the generated assembly — an internal Hoare bug (the checked-valid program's codegen is wrong), not a problem with the input. |
| `6` | `ld` failed to link the generated object — likewise an internal Hoare bug. |
| `64` | Usage error (missing/nonexistent input file, bad flag) — `build/codegen` never ran. |

Any other exit code (`0`-`4`, or `112`/`113` under `--stack-trace`) is
`build/codegen`'s own, passed straight through unchanged — see "Exit
codes" below.

## Stack-corruption self-check

Setting `POSTULATE_STACK_CHECK=1` in `build/codegen`'s environment makes
it emit two extra pieces of debug-only instrumentation into the compiled
program, on top of the normal output:

- **Stack-pointer balance check**: `_start` records its entry `rsp`,
  calls `pf_main`, and compares `rsp` again once it returns. A mismatch
  means something in the call tree left the stack unbalanced (a leaked
  `push`/`pop` or `sub`/`add rsp` pair) — exits **113** with a diagnostic
  on stderr instead of running the normal exit path.
- **Per-function stack canary**: every function plants a fixed magic
  value at `[rbp - 8]` (immediately below the saved `rbp`/return address)
  in its prologue and verifies it's unchanged in its epilogue — every
  local's own stack offset shifts down by 8 bytes to make room, see
  `compute_local_offsets`. A mismatch means a local array/struct write
  went out of bounds (Stage 0 has no bounds checking for a dynamic/
  computed index — see the language reference's implementation-status
  notes) and overwrote the canary on its way toward the saved frame —
  exits **112** with a diagnostic on stderr.

With the environment variable unset — every normal invocation of
`build/codegen`, including everything a real `hoare`-compiled program
goes through — neither check is emitted; output is byte-for-byte
identical to before this existed. This is debug/test-only instrumentation
for the compiler's own regression suite, not a language feature: Postulate
source has no way to opt into it, and it adds no cost to a normal build.

## Release image

`Dockerfile.release` packages just the compiler and what `./hoare` needs
to run it — `build/codegen`, the `hoare` script, `nasm`/`ld`/`bash`, and
the language reference — for other developers who just want to compile
Postulate programs, not build Hoare from source or run its test suite.
Nothing from the dev/test toolchain (`build/lexer`/`build/parser`/
`build/checker`, the `.asm` sources, `tests/`) is present. It's built
`FROM` the already fully-tested dev image (`postulate-hoare` above must
exist first), so a release is always exactly what the full test suite
just verified — no separate logic of its own.

Build from the **repository root** (the context needs to see both
`Hoare/` and `docs/`):

```powershell
docker build -t postulate-hoare Hoare
docker build -f Hoare/Dockerfile.release -t postulate-hoare-release .
```

Use — `hoare` is the image's `ENTRYPOINT`, and `WORKDIR` is `/work`, so
no `--entrypoint`/`-w` override is needed, unlike the dev image below:

```powershell
docker run --rm -v ${PWD}:/work postulate-hoare-release test.ptl
```

**Windows-host bind-mount note**: Docker Desktop's host bind mounts don't
always reflect a container-side `chmod +x` back onto the host filesystem
(NTFS has no native Unix executable bit) — if the produced binary won't
run directly from PowerShell/Bash on the host, run it from inside the
container instead (`docker run --rm -v ${PWD}:/work --entrypoint sh
postulate-hoare-release -c "hoare test.ptl -o /tmp/out && /tmp/out"`), or
copy it out with `docker cp` first.

The language reference lives inside the image at
`/opt/hoare/docs/postulate_v0_language_reference.md`; pull a local copy
with:

```powershell
docker run --rm --entrypoint cat postulate-hoare-release /opt/hoare/docs/postulate_v0_language_reference.md > language_reference.md
```

## Published releases

The version number here tracks Hoare **the tool**'s own release
maturity, not the Postulate v0 language it compiles — `v1.0.0` reflects
that Hoare itself is done: a complete, frozen Stage 0.

Pushing a `hoare-vX.Y.Z` tag runs `.github/workflows/release-hoare.yml`:
it builds and tests the dev image (exactly "Build and test" above),
re-packages the release image, and publishes it two ways:

- **The release image itself**, pushed to
  `ghcr.io/<owner>/postulate-hoare:vX.Y.Z` (and `:latest`) — use exactly
  like the locally-built release image above, just with that image name
  instead of `postulate-hoare-release`.
- **A self-contained tarball** (`scripts/bundle_release.sh`), attached
  to the GitHub Release itself, for anyone who'd rather not use Docker
  at all: extract it and run `./hoare test.ptl` directly. It bundles
  `nasm`/`ld` and their own shared-library dependencies (`ldd`-resolved
  against the exact Ubuntu 24.04 build the Docker image itself uses),
  so nothing needs separately installing on the target machine — a
  best-effort portability measure (works on essentially any
  actively-maintained x86-64 Linux distribution) rather than the same
  hermetic guarantee the Docker image gives; see the script's own
  header comment for the full reasoning.

## Run

```powershell
Get-Content <file>.ptl -Raw | docker run --rm -i postulate-hoare
```

(`ENTRYPOINT` runs `build/lexer`; to smoke-test `build/parser`/
`build/checker`/`build/codegen` ad hoc, run a shell in the image and
invoke them directly, or use a bind mount as the test scripts do.
`build/checker`/`build/codegen` take a plain `.ptl` file on stdin, no
directive line.)

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — input fully processed. Lexer/parser/codegen: dump/assembly written to stdout. Checker: `OK` written to stdout. |
| `1` | Lexical or parse error. Diagnostic on stderr, prefixed `lex error:` or `parse error:`. For the lexer, whatever was correctly lexed before the error is still flushed to stdout; the parser only dumps after a fully successful parse, so a parse error never has partial stdout output. |
| `2` | I/O-class / resource failure — input exceeds a fixed buffer (source buffer or AST arena), a `read`/`write` syscall failed, or a variable-arity list (call args / struct fields / array elements / statements / declarations / symbol table entries) exceeded its fixed cap. |
| `3` | Semantic error (`build/checker`/`build/codegen`). Diagnostic on stderr, prefixed `semantic error:`, same `at line L, col C (byte offset O)` position format as parse errors. |
| `4` | Code-generator error (`build/codegen` only). The program is semantically valid, but uses a construct outside this phase's implemented scope. Diagnostic on stderr, prefixed `codegen error:` — see the codegen spec section 9/10. |

The two codes below belong to a *compiled Postulate program*, not to
`build/codegen` itself — they only appear when that program was compiled
with `POSTULATE_STACK_CHECK=1` (see "Stack-corruption self-check" above)
and the self-check actually fired at runtime:

| Code | Meaning |
|---|---|
| `112` | Stack canary corrupted — an out-of-bounds local write. Diagnostic on stderr. |
| `113` | Stack pointer imbalance detected at program exit. Diagnostic on stderr. |

## Lexer token dump format

One line per token:

| Category | Example |
|---|---|
| identifier | `IDENT is_even` |
| keyword | `KW function` |
| integer literal | `INT 16n1F` (raw source text, not the computed value) |
| operator | `OP :=` |
| structural punctuation | `LBRACE` (bare, no spelling) |
| end of input | `EOF` (always the final line on success) |

## Parser fixture convention and dump format

Each `tests/parser_cases/*.ptl` fixture's **first line** is a directive —
`TYPE`, `EXPR`, `DECL`, `STMT`, `FUNC_BLOCK`, `TOP_LEVEL_DECL`, or `PROGRAM`
— naming which grammar rule to parse from the rest of the file. The AST is
dumped as a single-line, fully-parenthesized S-expression, e.g.
`(binary + (int 1) (int 2))`, `(array (ptr (base Node)) 3)`,
`(func_block (decls (decl_mut n (base int32))) (stmts (return (ident n))))`,
or `(function add (params (param a (base int32)) (param b (base int32)))
(base int32) (func_block (decls) (stmts (return (binary + (ident a)
(ident b))))))` — see the parser spec's dump-format table for the full
set of forms.

## Layout

```
hoare                  the unified compiler CLI (see "Compiling a program")
Dockerfile              dev/test image (see "Build and test")
Dockerfile.release       release image (see "Release image")
src/config.inc        size constants (buffers, AST arena, list-arity cap)
src/tokens.inc         token kind constants + 32-byte token struct layout
src/lexer.asm            lex_next -- pure tokenizer, no syscalls, shared by all binaries
src/runtime.asm/.inc       shared syscall I/O + diagnostic formatting, shared by all binaries
src/main.asm                lexer driver: _start, format_and_emit_token, lex-error reporting
src/ast.inc/.asm              AST node kinds/layout + arena bump allocator
src/parser_tokens.asm          token lookahead buffer (on lex_next) + parser_expect + report_parse_error
src/type_parser.asm             parse_type
src/expr_parser.asm              parse_expr's precedence chain + variable-arity lists
src/stmt_parser.asm               parse_decl / parse_stmt / parse_block / parse_func_block
src/top_parser.asm                 parse_function / parse_struct_decl / parse_extern_decl / parse_program
src/ast_dump.asm                    AST -> S-expression dump (build/parser only)
src/parser_main.asm                  parser driver: _start, directive-line handling, dispatch
src/symtab.inc/symtab.asm              symbol-table record layouts + global/local tables + diagnostics
src/sema_types.asm                      resolve_type / types_equal / canonical type singletons
src/sema_expr.asm                        check_expr, find_offset, is_valid_lvalue
src/sema_stmt.asm                         check_stmt / check_program / extern-whitelist validation
src/checker_main.asm                       checker driver: _start, no directive (always whole-program)
src/codegen_types.asm                       type_size / struct_size / field_offset / field_type
src/codegen_expr.asm                         gen_rvalue / gen_lvalue / gen_user_call / gen_extern_call
src/codegen_stmt.asm                          gen_decl / gen_stmt / gen_block / gen_func_block
src/codegen_program.asm                        gen_function / gen_program / stack-frame layout
src/codegen_composite.asm                       struct-/array-literal codegen, composite copy, broadcast-init
src/codegen_main.asm                             codegen driver: _start, no directive (always whole-program)
tests/cases/                fixtures for build/lexer
tests/parser_cases/          fixtures for build/parser (directive line + *.ptl + *.expected.*)
tests/blackbox_cases/         whole-program fixtures for build/parser (all use the PROGRAM directive)
tests/checker_cases/           fixtures for build/checker (no directive; *.ptl + *.expected.*)
tests/codegen_cases/            fixtures for build/codegen (no directive; *.ptl + *.expected.*, actually run)
tests/stack_check_cases/         hand-written NASM sanity fixtures for the POSTULATE_STACK_CHECK=1 self-check
```
