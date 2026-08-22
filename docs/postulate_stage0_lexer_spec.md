# Postulate Stage 0 — Lexer Technical Specification

> This document is the technical specification of the Stage 0 bootstrap
> compiler's **lexical analyzer** (tokenizer). It is a prerequisite for, and
> complement to, [postulate_stage0_spec.md](postulate_stage0_spec.md) (grammar,
> semantics, design decisions) — details not repeated here (keyword list,
> lexical grammar) should be taken from there. The parser, AST construction,
> and LLVM IR emission are **not** covered by this document; they will get
> their own specification when their turn comes.

---

## 1. Purpose and Scope

The lexer is a standalone, independently compilable, runnable, independently
testable binary: it reads source code (stdin), breaks it into a sequence of
tokens, and prints them in textual form (stdout). Its purpose is twofold:

1. **Immediate goal:** to prove that the Stage 0 toolchain (NASM + `ld`, under
   Docker, without libc) works, and that the lexical grammar (see chapter 4 of
   the main spec) can be implemented correctly in pure syscall-based assembly.
2. **Long-term goal:** the lexer's internal token-producing routine
   (`lex_next`) will be reusable, unchanged, by the parser once it is built —
   for this reason the lexer and the test driver built around it are strictly
   separated (see chapters 3 and 5).

---

## 2. Toolchain and Build Environment

| Decision | Choice | Rationale |
|---|---|---|
| Assembler | **NASM**, Intel syntax | More readable than AT&T-syntax GNU `as` — better fits the project's formal, precise documentation style. |
| Linker | `ld` directly | No `gcc` driver, no `crt0`, no libc — the entry point is our own `_start`. |
| Link flags | `-static -no-pie -e _start` | Modern Ubuntu's `ld` tries to generate a PIE (`ET_DYN`) by default, which — combined with a custom `_start` and absolute-addressed code (e.g. the jump table, see 6.1) — would fail at runtime with inexplicable errors. `-static -no-pie` forces plain `ET_EXEC`, position-dependent linking — exactly what the code expects. |
| Build/test environment | Docker, `ubuntu:24.04` | The Windows host has no native ELF64 toolchain; chapter 2 of the main spec also mandates parity with the `ubuntu-latest` CI environment. The image build step runs *both* the compilation *and* the test suite — a single `docker build` is the complete pass/fail gate. |
| Packages in the image | `nasm`, `binutils`, `bash`, `diffutils` | The minimum required for compilation and test diffing. |

---

## 3. Directory Structure

```
Hoare/
  README.md                # build/test commands, exit codes, token-dump format
  Dockerfile
  .dockerignore
  scripts/
    build.sh                # nasm + ld, runs inside the container
    run_tests.sh             # the fixture runner, runs inside the container
  src/
    config.inc               # SRC_BUF_SIZE / OUT_BUF_SIZE constants
    tokens.inc                # TOK_* kind constants + the token-struct layout
    lexer.asm                 # skip_trivia + lex_next + keyword/number recognition — contains no syscalls
    main.asm                  # _start, read_all/write_all, driver loop, diagnostics
  tests/
    cases/
      01_function_basic.{ptl,expected.stdout,expected.stderr,expected.exit}
      02_integer_literals.{...}
      03_operators.{...}
      04_comments.{...}
      05_lexer_error.{...}
      06_unterminated_comment.{...}
      07_based_form_empty_digits.{...}
```

**The point of the `lexer.asm` / `main.asm` split:** `lexer.asm` contains
exclusively the actual tokenizing engine (`skip_trivia`, `lex_next`, keyword
and number recognition), and **calls no syscalls whatsoever** — it only reads
from the buffer passed in by the caller and writes into the token-struct
passed in by the caller. `main.asm` owns all the syscalls, the stdin-reading
loop, the driver print loop, and all diagnostic formatting. This is what
allows a future parser to link directly against `lexer.asm` without touching
`main.asm`.

The `Hoare/build/` directory (compilation artifacts) goes into `.gitignore`.

---

## 4. Token Representation

### 4.1 Token-kind Constants

Every keyword, operator, and punctuation mark has its own **separate** kind
constant (not a generic `KEYWORD`/`OP` tag that would later need to be
re-identified from text) — this lets a future parser branch directly on
`kind`, without text comparison.

| Category | Constants | Value Range |
|---|---|---|
| Special | `TOK_EOF`, `TOK_IDENT`, `TOK_INT` | 0–2 |
| Keywords (24 total) | `TOK_KW_FUNCTION`, `TOK_KW_STRUCT`, `TOK_KW_EXTERN`, `TOK_KW_MUT`, `TOK_KW_CONST`, `TOK_KW_IF`, `TOK_KW_ELSE`, `TOK_KW_WHILE`, `TOK_KW_RETURN`, `TOK_KW_TRUE`, `TOK_KW_FALSE`, `TOK_KW_NULL`, `TOK_KW_INT8`, `TOK_KW_INT16`, `TOK_KW_INT`, `TOK_KW_INT32`, `TOK_KW_INT64`, `TOK_KW_UINT8`, `TOK_KW_UINT16`, `TOK_KW_UINT`, `TOK_KW_UINT32`, `TOK_KW_UINT64`, `TOK_KW_BOOL`, `TOK_KW_VOID` | 10–33 |
| Structural punctuation | `TOK_COLON` (`:`), `TOK_SEMI` (`;`), `TOK_COMMA` (`,`), `TOK_DOT` (`.`), `TOK_LPAREN`, `TOK_RPAREN`, `TOK_LBRACE`, `TOK_RBRACE`, `TOK_LBRACKET`, `TOK_RBRACKET` | 40–49 |
| Operators | `TOK_ASSIGN` (`:=`), `TOK_EQ` (`==`), `TOK_NE` (`!=`), `TOK_LE` (`<=`), `TOK_GE` (`>=`), `TOK_SHL` (`<<`), `TOK_SHR` (`>>`), `TOK_ANDAND` (`&&`), `TOK_OROR` (`\|\|`), `TOK_BANG` (`!`), `TOK_MINUS`, `TOK_STAR`, `TOK_AMP` (`&`), `TOK_SLASH`, `TOK_PERCENT`, `TOK_PLUS`, `TOK_LT`, `TOK_GT`, `TOK_CARET` (`^`), `TOK_PIPE` (`\|`) | 60–79 |
| Errors | `TOK_ERROR_COMMENT` (unterminated block comment), `TOK_ERROR` (unrecognized character) | 253–254 |

`:` counts as structural punctuation (it occurs in type annotations and field
declarations, not as an expression operator), whereas `:=` — although it
begins with `:` — is an operator, since assignment is an expression/statement-
level operator.

### 4.2 Token Struct (32 bytes)

| Field | Offset | Size | Contents |
|---|---|---|---|
| `kind` | 0 | 8 bytes | one of the kind constants above |
| `offset` | 8 | 8 bytes | the byte offset of the token's first byte in the source buffer |
| `length` | 16 | 8 bytes | the length of the token's source span, in bytes |
| `value` | 24 | 8 bytes | for `TOK_INT`, the computed numeric value; otherwise 0 |

**Why offset+length instead of a copied string?** The source buffer stays
resident for the entire run (there is no dynamic memory management in the
project, see chapter 2 of the main spec) — so any consumer (the test driver
now, a parser later) can slice directly into the source buffer using
`offset`/`length`, without a separate string table.

### 4.3 Numeric Value Computation Happens in the Lexer

The `value` field of `TOK_INT` is computed by `lex_next` itself during
scanning (not as a separate step), since the accumulation is a free byproduct
of reading the digit sequence:

- `decimal_form`: `value = value*10 + digit` for every digit read.
- `based_form` (`digit+ "n" value_digit+`): the `digit+` prefix, interpreted
  as decimal, gives the `base`; after that, for every `value_digit`,
  `value = value*base + digit_value` (`0-9 → 0-9`, `a-f`/`A-F → 10-15`,
  regardless of the base). The lexer does **not** check that
  `base ∈ {2, 8, 10, 16}` — per the main spec's explicit design decision
  ("the grammar is more permissive than the semantics"), that is the
  responsibility of a later semantic phase. On overflow, the 64-bit `value`
  simply wraps around — there is no separate overflow check at this level.

---

## 5. Internal Calling Convention

Since there is no inherited ABI for internal (non-syscall) routine calls, we
consistently follow the System V AMD64 caller-saved/callee-saved split:

- **Caller-saved** (the callee may freely overwrite): `rax, rcx, rdx, rsi, rdi, r8, r9, r10, r11`
- **Callee-saved** (the callee must `push`/`pop` if it touches them): `rbx, rbp, r12, r13, r14, r15`

### `lex_next` Signature

```
in:  rdi = src_buf pointer
     rsi = cursor (byte offset, where the search should start)
     rdx = valid length of the buffer (in bytes)
     rcx = pointer to a 32-byte token struct allocated by the caller (to be filled in)
out: rax = the new cursor position (this goes into rsi on the next call)
     [rcx] = the filled-in token struct
```

There is no hidden global "current position" — the caller explicitly passes
in and receives back the cursor. This is what allows a future recursive-
descent parser to trivially save/restore cursor positions for
lookahead/backtracking purposes, without having to manage any global state.

---

## 6. Lexical Analysis Algorithm

### 6.1 Dispatch: 256-entry Jump Table

`lex_next` decides via a 256-entry jump table indexed by the value of the
first non-trivia byte (`dq` address array, `jmp [table + rax*8]`) — not a
chain of stacked `cmp`/`je` comparisons. Every letter-valued byte (52 of them)
points to the same identifier-recognition branch, every digit byte (10 of
them) points to the same number-recognition branch, every punctuation mark
gets its own small handler, and every other byte goes to the error branch
(`TOK_ERROR`). Deciding whether the identifier/number *continues* (is the
next byte still an identifier character?) is done with a simple range
comparison, not a separate table — maintaining a single large table is worth
it (it replaces roughly 60 chained comparisons), but it's not worth
tabulating everything.

### 6.2 Maximal Munch — Two-character Operators

Seven starting bytes require one byte of lookahead: `: = ! < > & |`. In every
case, `cursor+1 < buffer_length` must be checked before examining the next
byte — a source that ends with exactly one such byte must not read past the
end of the buffer.

| Starting byte | If next is `=` | If next is something else | Has a standalone (1-character) form? |
|---|---|---|---|
| `:` | `:=` (`TOK_ASSIGN`) | `:` (`TOK_COLON`) | yes |
| `=` | `==` (`TOK_EQ`) | **`TOK_ERROR`** | **no** |
| `!` | `!=` (`TOK_NE`) | `!` (`TOK_BANG`) | yes |
| `<` | `<=` (`TOK_LE`); if the next is `<`: `<<` (`TOK_SHL`) | `<` (`TOK_LT`) | yes |
| `>` | `>=` (`TOK_GE`); if the next is `>`: `>>` (`TOK_SHR`) | `>` (`TOK_GT`) | yes |
| `&` | if the next is `&`: `&&` (`TOK_ANDAND`) | `&` (`TOK_AMP`) | yes |
| `\|` | if the next is `\|`: `\|\|` (`TOK_OROR`) | `\|` (`TOK_PIPE`) | yes |

**Critical case:** a bare `=` is **never** a valid token (the full grammar has
no standalone `=` — it only occurs as part of `:=`, `==`, `!=`, `<=`, `>=`).
`=` still gets its own dispatch entry (because `==` begins with this byte); if
the lookahead does not find `=`, the result is `TOK_ERROR`, **not** a fallback
to some standalone token form — this is the only one of the seven cases where
"doesn't match the two-character form" is an error rather than a valid
single-character token.

`/` must be handled separately (see 6.3), because its two-character forms
(`//`, `/*`) are not operators — they are entirely absorbed by the trivia
loop and never become tokens.

Every other single-character token (`; , . ( ) { } [ ] - * % + ^`) dispatches
directly, without lookahead.

### 6.3 Trivia: Whitespace and Comments

`skip_trivia` runs at the start of every `lex_next` call and loops until it
finds actual (non-trivia) content — because nested sequences of
whitespace/comments (`"  // c\n  /* c */  identifier"`) cannot be handled in
a single pass:

1. While the byte is whitespace (space, tab, CR, LF): advance.
2. If the byte is `/`, it examines the next byte:
   - `/`: line comment — advances up to the next `\n` or end of file. If the
     file ends without the line comment's terminating `\n`, that is a
     **successful** termination, not an error (under a strict reading of the
     grammar's `line_comment ::= "//" ... newline`, this would be an error,
     but the specification is deliberately more permissive here — rejecting
     a comment that ends at end-of-file without a `\n` would be unjustifiably
     strict).
   - `*`: block comment — records the position of the opening `/*` (for the
     error message) and searches for the `*/` byte sequence. If found, it
     advances past it and continues the trivia loop. **If the end of the
     buffer is reached before `*/`, this is an error** (`TOK_ERROR_COMMENT`);
     `offset` points to the position of the opening `/*` (not to the end of
     the file) — the start of the unterminated comment is the useful,
     actionable reference point.
   - anything else: not a comment, `/` itself is `TOK_SLASH` — this is no
     longer the trivia loop, but an actual token.
3. Otherwise: the loop ends, this byte is the start of the next actual token.
4. If the cursor has reached the end of the buffer: `TOK_EOF`
   (`offset = buffer_length, length = 0`).

### 6.4 Identifier and Keyword Recognition — Length-based Bucketing

There are 24 keywords in total. The chosen strategy is **length-based
bucketing**, neither a trie nor a plain 24-entry linear search: a hand-written
NASM trie would be disproportionately error-prone relative to the amount of
code needed for 24 entries, while an unconditional 24-entry linear search
would waste an excessive number of comparisons on the (most common) case
where the identifier matches no keyword at all.

| Length | Keywords |
|---|---|
| 2 | `if` |
| 3 | `mut`, `int` |
| 4 | `else`, `true`, `null`, `int8`, `bool`, `void`, `uint` |
| 5 | `const`, `while`, `false`, `int16`, `int32`, `int64`, `uint8` |
| 6 | `struct`, `extern`, `return`, `uint16`, `uint32`, `uint64` |
| 8 | `function` |
| 1, 7, 9+ | *(empty — immediately `TOK_IDENT`, no comparison)* |

Lengths 1, 7, and 9+ — which cover every single-letter variable name (e.g.
`n`, `e`, `b`, `x`, `y`, `a`, `p`, all of which occur in the main spec's
sample program) — resolve to `TOK_IDENT` with zero string comparisons.
Within a matching bucket, a simple, byte-by-byte comparison decides the
match (not a word/dword-level packed comparison, which for short identifiers
would risk over-reading past the end of the buffer).

---

## 7. Error Handling and Diagnostics

`lex_next` **never** performs I/O and never exits — errors (`TOK_ERROR`,
`TOK_ERROR_COMMENT`) are returned just like any other token, as a plain token
kind. This preserves the "clean, reusable scanning routine" property on the
error path too: a parser embedded in a later, longer-lived compiler may
decide to collect multiple errors instead of exiting on the first one — that
decision must not be baked into the scanner.

The actual diagnostic behavior — formatting, writing to stderr, choosing the
exit code — happens exclusively in the `main.asm` driver loop:

- **`TOK_ERROR`** — covers two distinct subtypes, each with a different
  message, because the driver decides which one it is based on the
  `TOK_LENGTH_OFF` field (see the three `TOK_ERROR`-producing sites in
  `lexer.asm`):
  - **Unrecognized character** (`TOK_LENGTH_OFF = 1`, whether a bare `=` or
    any other unrecognized byte): writes to stderr: `lex error:
    unexpected character '@' (0x40) at line 3, col 12 (byte offset 41)`.
  - **Empty based-digit sequence** (`TOK_LENGTH_OFF = 0` — e.g. `16n`
    immediately followed by a non-hex-digit character or by end of file):
    writes to stderr: `lex error: based-form integer literal has no digits
    after 'n' at line L, col C (byte offset O)`. It does **not** use the
    "unexpected character" format — in this case the byte after the error
    position (if there even is one) is not itself invalid in any way, so
    calling it an "invalid character" would be misleading (and at end of
    file it would read a byte that doesn't even exist). See
    `tests/cases/07_based_form_empty_digits`.
  For both subtypes: it prints to stdout the tokens correctly recognized up
  to that point (the prefix before the error is not lost — see chapter 9),
  and `exit(1)`.
- **`TOK_ERROR_COMMENT`** (unterminated block comment): similarly, `lex
  error: unterminated block comment starting at line 5, col 1 (byte offset
  88)`, the same flush-then-exit(1) behavior.
- **Exit codes:** `0` = success, `1` = lexical error (bad character /
  unterminated comment), `2` = I/O-related error (buffer too small,
  `read`/`write` syscall error) — separating these two error classes matters
  so the test suite (see chapter 10) can distinguish between them.

**Line/column computation** is deliberately **not** on `lex_next`'s hot path
— it happens only on the error-reporting path, via a separate helper routine
that counts `\n` bytes in a single pass from the start of the buffer up to
the error position (`line = counter+1`, `column = offset -
last_newline_offset`). This is O(n), but it runs only once, on the error
path, in a program that is exiting anyway — it is not worth complicating
`lex_next`'s calling convention for this (which would require extra state on
every call).

---

## 8. I/O Mechanics

### 8.1 Static Buffers

```nasm
SRC_BUF_SIZE equ 1024*1024   ; 1 MiB
OUT_BUF_SIZE equ 65536       ; 64 KiB
```

Both are in `.bss` (`resb`), **not** in `.data` (filled with `db 0`) — the
kernel zeroes `.bss` at load time, and it takes up no space in the on-disk
ELF file, whereas a `db 0` × 1 MiB block would literally grow the binary's
size by one megabyte.

### 8.2 Reading (stdin → `src_buf`)

Repeated `read(0, ...)` calls into `src_buf`, until EOF (`rax == 0`) or the
buffer fills up without EOF (the latter is an error, `exit(2)`, since the
source exceeds the fixed 1 MiB buffer size). The loop handles partial reads
(POSIX `read` may return fewer bytes than requested, even before EOF — one
must never assume a single `read` call reads everything).

### 8.3 Writing — a Shared `write_all`

A single reusable retry loop for both stdout (token dump) and stderr
(diagnostics), with the same partial-write handling.

### 8.4 Signed Checking of `rax`

On error, the raw Linux x86_64 syscall ABI returns `-errno` directly in `rax`
(there is no libc `errno` global variable). Every syscall return-value check
must be a **signed** comparison (`cmp rax, 0` / `jl`) — interpreted as an
unsigned byte count, an error would appear as "reading approximately 18
quintillion bytes".

---

## 9. Token-dump Format

The driver formats token kinds via a data-driven `{label, echo_spelling}`
table (not via per-kind branching):

| Category | Example kinds | Printed form |
|---|---|---|
| identifier | `TOK_IDENT` | `IDENT is_even` |
| keyword | any `TOK_KW_*` | `KW function` |
| integer literal | `TOK_INT` | `INT 16n1F` (prints the raw source text, not the computed value) |
| operator | `TOK_ASSIGN`, `TOK_EQ`, `TOK_PLUS`, … | `OP :=`, `OP ==`, `OP +` |
| structural punctuation | `TOK_LBRACE`, `TOK_SEMI`, `TOK_COLON`, … | `LBRACE`, `SEMI`, `COLON` (on its own, with no text) |
| end of input | `TOK_EOF` | closing `EOF` line on a successful run |

Explicitly printing the closing `EOF` line matters because it lets a dump
truncated by a crash be visually distinguished from a genuinely complete run.

---

## 10. Test Suite

Every fixture under `Hoare/tests/cases/` consists of a `.ptl` source file and
three expected-output files (`.expected.stdout`, `.expected.stderr`,
`.expected.exit`), which `scripts/run_tests.sh` diffs against the actual
output — for successful cases, `.expected.stderr` is empty and
`.expected.exit` is `0`.

| Fixture | What it covers |
|---|---|
| `01_function_basic` | Keywords, identifiers, parentheses/braces (e.g. the main spec's `is_even` sample function). |
| `02_integer_literals` | `decimal_form`, `based_form` in hex (`16n1F`) and octal (`8n17`), plus a syntactically valid but semantically invalid-base `based_form` (`99n5`), demonstrating the lexer's deliberate permissiveness. |
| `03_operators` | Every two-character operator alongside its one-character counterpart, in both directions, so that maximal-munch errors (in either direction) surface. |
| `04_comments` | Line and block comments containing token-like text inside them, proving that scanning correctly resumes after them. |
| `05_lexer_error` | A genuinely invalid byte (`@`), verifying: the correctly recognized prefix before the error appears on stdout, the exact stderr diagnostic, and `exit(1)`. |
| `06_unterminated_comment` | An unterminated `/*`, verifying `TOK_ERROR_COMMENT` and that the diagnostic points to the comment's *opening*, not to the end of the file. |
| `07_based_form_empty_digits` | `16n;` — empty based-digit sequence, verifying the dedicated `"has no digits after 'n'"` message, not the "unexpected character" form (see chapter 7). |

---

## 11. Known Pitfalls (to Keep in Mind During Implementation)

- **The `syscall` instruction unconditionally clobbers `rcx` and `r11`** (the
  kernel uses them to save the return RIP/RFLAGS) — one must never assume
  these survive a `syscall` call. Related to this: the raw syscall ABI
  expects the 4th parameter in `r10`, not `rcx` (not relevant for
  `read`/`write`/`exit` since they take ≤3 parameters, but it will matter as
  soon as the main spec's `sys_mmap` — 6 parameters — is implemented).
- **The internal calling convention in chapter 5 is entirely our own
  invention** — no tool checks compliance with it. A short comment at the
  start of every routine noting which registers it touches, and consistent
  `push`/`pop`-ing of callee-saved registers, is the only safety net.
- **NASM section conventions:** `.text` for code, `.data` for initialized
  data (jump table entries, error-message text, dump-format table), `.bss`
  (`resb`) for the two fixed-size buffers (see 8.1) — correct use of `.bss`
  is what keeps the on-disk binary size low.
- **`-static -no-pie` linking** — see the table in chapter 2; if omitted,
  this is the most likely source of an error that is silent at build time
  and mysterious at runtime.
- **Stack alignment** (`rsp % 16 == 0` at every `call` point), as soon as
  internal calls (`call lex_next`, `call write_all`) appear in `main.asm` —
  a cheap discipline to maintain, but neglecting it can cause latent bugs if
  an SSE instruction (e.g. `movaps`, which requires 16-byte alignment) is
  ever introduced into the code.
- **Bounds checking at all seven lookahead points in 6.2** — seven separate
  locations, seven separate chances to get it wrong; it is worth factoring
  this out into a shared "peek-or-EOF" helper routine rather than checking
  it by hand in seven separate places.

---

## 12. Suggested Implementation Order

It is worth retiring the toolchain/linking risks before the lexical logic —
these are the least familiar parts of the project, and the most likely place
for a "it compiles, but the binary mysteriously crashes" type of bug to
arise.

1. Skeleton structure + `Dockerfile` + `scripts/build.sh`; a trivial
   `_start` that just calls `exit(0)`. `docker build` should be green
   before any lexical logic is written — this verifies Docker availability,
   `-static -no-pie` linking, and the container pipeline itself.
2. Implement `read_all`/`write_all`; for now, `_start` just echoes whatever
   it gets from stdin back to stdout, unchanged. This verifies
   partial-read/write handling and the buffer-full error branch.
3. Finalize `tokens.inc`/`config.inc` (struct layout, kind constants) —
   every subsequent step builds on this.
4. `skip_trivia` on its own (whitespace + both comment forms, including the
   unterminated-comment error).
5. Dispatch + punctuation/operators (identifiers/numbers point to an error
   stub for now) — verify with the `03` fixture.
6. Identifier + keyword bucket matching — verify with the `01` fixture.
7. Number recognition (decimal + `based_form`, including the empty
   `value_digit+` error) — verify with the `02` fixture.
8. Error diagnostics in `main.asm` (line/column, stderr formatting, exit
   codes) — verify with the `05`/`06` fixtures.
9. Full driver loop + format table + `EOF` sentinel — run the complete test
   suite.
10. `Hoare/README.md` — document build/test commands, exit codes, dump
    format.
