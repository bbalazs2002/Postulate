# Postulate Stage 0 — lexer, parser & semantic checker

Three standalone, Docker-built, Docker-tested x86_64 NASM binaries — the
first steps of what will become the unified **`hoare`** compiler CLI:

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
  resolution and core type checking over it, writing `OK` to stdout on
  success. Phase 1 of semantic analysis: symbol tables, type equality,
  extern-whitelist validation, lvalue/const rules — see
  [docs/postulate_stage0_semantics_spec.md](../docs/postulate_stage0_semantics_spec.md)
  for exactly what's covered and what's still deferred.

## Build and test

```powershell
docker build -t postulate-stage0-lexer Stage0
```

This is the single, complete pass/fail gate: it assembles all three
binaries (`scripts/build.sh`) and runs four fixture suites as build
steps — a failing test fails the build:

- `scripts/run_tests.sh` — lexer fixtures (`tests/cases/`).
- `scripts/run_parser_tests.sh` — **white-box** parser fixtures
  (`tests/parser_cases/`), each scoped to a single grammar rule via a
  directive.
- `scripts/run_blackbox_tests.sh` — **black-box** parser fixtures
  (`tests/blackbox_cases/`), each a complete, realistic `PROGRAM` (classic
  "programozási tétel" implementations and combinations, plus one
  compiler-scale multi-declaration program), checked only by observable
  behavior (exit code / stdout / stderr) — see the parser spec section 16.
- `scripts/run_checker_tests.sh` — semantic-checker fixtures
  (`tests/checker_cases/`), one correct/incorrect pair per rule — see the
  semantics spec section 9. (The 12 `*_valid` black-box programs above are
  also re-verified against `build/checker` as part of that phase's
  verification, though not as a separate scripted suite.)

## Run

```powershell
Get-Content <file>.ptl -Raw | docker run --rm -i postulate-stage0-lexer
```

(`ENTRYPOINT` runs `build/lexer`; to smoke-test `build/parser`/`build/checker`
ad hoc, run a shell in the image and invoke them directly, or use a bind
mount as the test scripts do. `build/checker` takes a plain `.ptl` file on
stdin, no directive line.)

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — input fully processed. Lexer/parser: dump written to stdout. Checker: `OK` written to stdout. |
| `1` | Lexical or parse error. Diagnostic on stderr, prefixed `lex error:` or `parse error:`. For the lexer, whatever was correctly lexed before the error is still flushed to stdout; the parser only dumps after a fully successful parse, so a parse error never has partial stdout output. |
| `2` | I/O-class / resource failure — input exceeds a fixed buffer (source buffer or AST arena), a `read`/`write` syscall failed, or a variable-arity list (call args / struct fields / array elements / statements / declarations / symbol table entries) exceeded its fixed cap. |
| `3` | Semantic error (`build/checker` only). Diagnostic on stderr, prefixed `semantic error:`, same `at line L, col C (byte offset O)` position format as parse errors. |

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
src/config.inc        size constants (buffers, AST arena, list-arity cap)
src/tokens.inc         token kind constants + 32-byte token struct layout
src/lexer.asm            lex_next -- pure tokenizer, no syscalls, shared by both binaries
src/runtime.asm/.inc       shared syscall I/O + diagnostic formatting, shared by both binaries
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
tests/cases/                fixtures for build/lexer
tests/parser_cases/          fixtures for build/parser (directive line + *.ptl + *.expected.*)
tests/blackbox_cases/         whole-program fixtures for build/parser (all use the PROGRAM directive)
tests/checker_cases/           fixtures for build/checker (no directive; *.ptl + *.expected.*)
```