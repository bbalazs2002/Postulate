# Postulate Stage 0 — lexer

Standalone, Docker-built, Docker-tested x86_64 NASM tokenizer. Reads a
Postulate source file on stdin, writes a text token dump to stdout. No
parser/AST/codegen yet — see [docs/postulate_stage0_lexer_spec.md](../docs/postulate_stage0_lexer_spec.md)
for the full design this implements.

## Build and test

```powershell
docker build -t postulate-stage0-lexer Stage0
```

This is the single, complete pass/fail gate: it assembles (`scripts/build.sh`)
and runs the full fixture suite (`scripts/run_tests.sh`) as build steps. A
failing test fails the build.

## Run

```powershell
Get-Content <file>.ptl -Raw | docker run --rm -i postulate-stage0-lexer
```

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success — all of stdin tokenized, dump written to stdout. |
| `1` | Lexical error (unexpected character, or unterminated block comment). Diagnostic on stderr; whatever was correctly lexed before the error is still flushed to stdout. |
| `2` | I/O-class failure — input exceeds the fixed 1 MiB source buffer, or a `read`/`write` syscall failed. |

## Token dump format

One line per token:

| Category | Example |
|---|---|
| identifier | `IDENT is_even` |
| keyword | `KW function` |
| integer literal | `INT 16n1F` (raw source text, not the computed value) |
| operator | `OP :=` |
| structural punctuation | `LBRACE` (bare, no spelling) |
| end of input | `EOF` (always the final line on success) |

## Layout

```
src/config.inc   size constants
src/tokens.inc   token kind constants + 32-byte token struct layout
src/lexer.asm    lex_next -- pure tokenizer, no syscalls, reusable by a future parser
src/main.asm     _start, syscall I/O, diagnostics, driver loop
tests/cases/     fixtures: *.ptl + *.expected.{stdout,stderr,exit}
```
