# Postulate Stage 0 — lexer & parser (type/expr slice)

Two standalone, Docker-built, Docker-tested x86_64 NASM binaries:

- **`build/lexer`** — reads a Postulate source file on stdin, writes a text
  token dump to stdout. See
  [docs/postulate_stage0_lexer_spec.md](../docs/postulate_stage0_lexer_spec.md).
- **`build/parser`** — reads a directive-prefixed snippet on stdin (`TYPE` or
  `EXPR`, see below), parses it as a `type` or `expr` grammar rule, and
  writes an S-expression AST dump to stdout. Statements, declarations, and
  top-level (`function`/`struct`/`extern`) parsing are not implemented yet.
  See [docs/postulate_stage0_parser_spec.md](../docs/postulate_stage0_parser_spec.md).

## Build and test

```powershell
docker build -t postulate-stage0-lexer Stage0
```

This is the single, complete pass/fail gate: it assembles both binaries
(`scripts/build.sh`) and runs both fixture suites (`scripts/run_tests.sh` for
the lexer, `scripts/run_parser_tests.sh` for the parser) as build steps. A
failing test fails the build.

## Run

```powershell
Get-Content <file>.ptl -Raw | docker run --rm -i postulate-stage0-lexer
```

(`ENTRYPOINT` runs `build/lexer`; to smoke-test `build/parser` ad hoc, run a
shell in the image and invoke it directly, or use a bind mount as the test
scripts do.)

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — input fully processed, dump written to stdout. |
| `1` | Lexical or parse error. Diagnostic on stderr, prefixed `lex error:` or `parse error:`. For the lexer, whatever was correctly lexed before the error is still flushed to stdout; the parser only dumps after a fully successful parse, so a parse error never has partial stdout output. |
| `2` | I/O-class / resource failure — input exceeds a fixed buffer (source buffer or AST arena), a `read`/`write` syscall failed, or a variable-arity list (call args / struct fields / array elements) exceeded its fixed cap. |

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

Each `tests/parser_cases/*.ptl` fixture's **first line** is a directive,
`TYPE` or `EXPR`, naming which grammar rule to parse from the rest of the
file. The AST is dumped as a single-line, fully-parenthesized S-expression,
e.g. `(binary + (int 1) (int 2))` or `(array (ptr (base Node)) 3)` — see the
parser spec's dump-format table for the full set of forms.

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
src/ast_dump.asm                  AST -> S-expression dump
src/parser_main.asm                parser driver: _start, directive-line handling, dispatch
tests/cases/                fixtures for build/lexer
tests/parser_cases/          fixtures for build/parser (directive line + *.ptl + *.expected.*)
```
