# Postulate Stage 0 — Parser Technical Specification

> This document is the technical specification of the **parser** for the
> Stage 0 bootstrap compiler: types, expressions, statements, declarations,
> blocks, and the top-level declarations (`type`, `expr`, `stmt`, `decl`,
> `block`, `func_block`, `function`, `struct_decl`, `extern_decl`, `params`,
> `program`). Its prerequisites are
> [postulate_stage0_spec.md](postulate_stage0_spec.md) (grammar, semantics)
> and [postulate_stage0_lexer_spec.md](postulate_stage0_lexer_spec.md) (the
> already-completed, tested lexer — everything described here builds on its
> `lex_next` routine). With this pass, `build/parser` covers the **entire**
> Stage 0 EBNF grammar — from the `program` rule down to the deepest
> expression level.

---

## 1. Goal and scope

The `type` and `expr` grammar rules (see chapter 4 of the main spec) are the
most self-contained, most widely reused building blocks — declarations,
parameters, struct fields all reference a type; statements, initializers all
reference an expression. That is why they got the first, independently
testable parser slice. On top of that sits the second slice: **statements,
declarations, blocks** — everything needed to parse a function body
(`func_block`). The third slice, closed out by this pass, is: **the
top-level declarations** — `function`/`struct_decl`/`extern_decl`, the
`params`/`param` machinery they share, and the `program` rule that ties
everything together. With this, `build/parser` can process a complete
Stage 0 source file from beginning to end.

The goal is a **standalone `build/parser` binary** that reads from stdin a
source beginning with a directive line (`TYPE`, `EXPR`, `DECL`, `STMT`,
`FUNC_BLOCK`, `TOP_LEVEL_DECL`, or `PROGRAM`, see chapter 14), parses the
remainder according to the corresponding grammar rule, and writes the
resulting AST to stdout in textual, parenthesized form (an S-expression, see
chapter 12) — or, on a syntax error, writes a diagnostic to stderr and exits
with `exit(1)`.

---

## 2. Toolchain and build environment

Unchanged from the lexer (NASM, Intel syntax; `ld -static -no-pie`; Docker,
`ubuntu:24.04`) — see chapter 2 of the lexer spec. Alongside `build/lexer`, a
**second, standalone `build/parser` binary** is built, with its own
`_start`.

---

## 3. Extracting shared runtime code (`runtime.asm`)

The lexer driver (`main.asm`) contains the buffered syscall I/O (`read_all`,
`write_all`, `emit_str`, `flush_out`) and the diagnostic-building code
(`compute_line_col`, `err_append_str`, `err_append_dec`,
`err_append_hex_byte`). These (and their associated `.bss` data:
`src_buf`, `src_len`, `scratch_byte`, `out_buf`, `out_cursor`, `err_buf`,
`err_cursor`) now live in the `runtime.asm`/`runtime.inc` pair, which both
binaries link against. Everything specific to the lexer driver alone stays
in `main.asm`.

---

## 4. AST node representation

There is no dynamic memory allocation anywhere in the project (see chapter 2
of the main spec) — AST nodes live on top of a fixed-size **arena** (bump
allocator) and are never freed individually.

### 4.1 Node layout: 40 bytes, `kind` + 4 generic fields

| Field | Offset | Content |
|---|---|---|
| `kind` | 0 | one of the `AST_*` constants below |
| `a` | 8 | node-specific |
| `b` | 16 | node-specific |
| `c` | 24 | node-specific |
| `d` | 32 | node-specific |

### 4.2 Node kinds — types and expressions

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_TY_BASE` | built-in type tag (0 if a type referenced by identifier name; otherwise one of the `TOK_KW_INT8`..`TOK_KW_BOOL` constants) | `name_offset` | `name_len` | — |
| `AST_TY_POINTER` | `inner` (node ptr) | — | — | — |
| `AST_TY_ARRAY` | `elem` (node ptr) | `count` | — | — |
| `AST_EX_INT` | `value` | — | — | — |
| `AST_EX_BOOL` | `value` (0/1) | — | — | — |
| `AST_EX_NULL` | — | — | — | — |
| `AST_EX_IDENT` | `name_offset` | `name_len` | — | — |
| `AST_EX_UNARY` | `op` (`TOK_BANG`/`TOK_MINUS`/`TOK_STAR`/`TOK_AMP`) | `operand` (ptr) | — | — |
| `AST_EX_BINARY` | `op` (`TOK_ASSIGN`..`TOK_PIPE` range) | `left` (ptr) | `right` (ptr) | — |
| `AST_EX_INDEX` | `base` (ptr) | `index` (ptr) | — | — |
| `AST_EX_FIELD` | `base` (ptr) | `name_offset` | `name_len` | — |
| `AST_EX_CALL` | `callee` (ptr) | `args` (ptr to arena array, 0 if no arguments) | `arg_count` | — |
| `AST_EX_STRUCT_LIT` | `name_offset` | `name_len` | `fields` (ptr to array of `AST_FIELD_INIT` ptrs) | `field_count` (≥1) |
| `AST_EX_ARRAY_LIT` | `elems` (ptr to ptr array) | `elem_count` (≥1) | — | — |
| `AST_FIELD_INIT` | `name_offset` | `name_len` | `value` (ptr) | — |

**There is no separate "pointer-array" node kind.** `*T[N]` (without
parentheses, the default form) is built as
`AST_TY_ARRAY{ elem = AST_TY_POINTER{T} }`; `*(T[N])` (with parentheses) as
`AST_TY_POINTER{ inner = AST_TY_ARRAY{T, N} }` — the same two node kinds,
just assembled in a different order (see chapter 7).

### 4.3 Node kinds — statements, declarations, blocks

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_DECL_MUT` | `name_offset` | `name_len` | `type` (ptr) | `init` (ptr, 0 if absent) |
| `AST_DECL_CONST` | `name_offset` | `name_len` | `type` (ptr) | `init` (ptr, 0 if absent) |
| `AST_ASSIGN_PAIR` | `lvalue` (expression-shaped ptr) | `rhs` (ptr) | — | — |
| `AST_STMT_ASSIGN` | `pairs` (ptr to arena array) | `pair_count` (always ≥1, see below) | — | — |
| `AST_STMT_IF` | `cond` (ptr) | `then_block` (`AST_BLOCK` ptr) | `else_block` (ptr, 0 if absent) | — |
| `AST_STMT_WHILE` | `cond` (ptr) | `body` (`AST_BLOCK` ptr) | — | — |
| `AST_STMT_RETURN` | `expr` (ptr, 0 if absent) | — | — | — |
| `AST_STMT_EXPR` | `expr` (ptr) | — | — | — |
| `AST_BLOCK` | `stmts` (ptr to arena array) | `stmt_count` (≥0 — `stmt*`) | — | — |
| `AST_FUNC_BLOCK` | `decls` (ptr to arena array) | `decl_count` (≥0) | `stmts` (ptr to arena array) | `stmt_count` (≥0) |

**`AST_DECL_MUT`/`AST_DECL_CONST` are two separate `kind`s, not a shared node
with a flag field** — this frees up a fourth field (`d` = `init`), the same
way `AST_EX_BOOL` did not get a separate "bool tag" field either — the
`value` (0/1) itself carries the meaning.

**`AST_STMT_ASSIGN.pair_count` can never be 0**, so — unlike
`array_literal`/`struct_literal` — there is no "empty list error" branch: the
first pair is guaranteed to exist by the structure of the parsing algorithm
itself — the pair-building loop only starts after we have already confirmed
that `tok_cur == TOK_ASSIGN` (see chapter 9).

**`lvalue` does not get its own node kind** — it reuses the existing
`AST_EX_UNARY` (the `*lvalue` form), `AST_EX_IDENT`, `AST_EX_INDEX`,
`AST_EX_FIELD` nodes, because `lvalue` is grammatically a strict subset of
`expr` (see the rationale in chapter 9).

### 4.4 Arena and allocator

```nasm
AST_ARENA_SIZE equ 1024*1024   ; 1 MiB (in config.inc, following the pattern of SRC_BUF_SIZE)
MAX_LIST_ARITY equ 256          ; fixed upper bound for a single variable-arity list
```

`ast_arena: resb AST_ARENA_SIZE` + `ast_cursor: resq 1` (bump pointer). The
`.bss` is zeroed at load time — since this is a single, one-shot-run
process, node fields can be treated on a "missing = 0" basis without
explicit zeroing.

- **`ast_alloc_node`** — in: `rdi` = `kind`. out: `rax` = pointer to a fresh
  40-byte node tagged with `kind`.
- **`ast_alloc_bytes`** — in: `rdi` = byte count (always `element_count*8`,
  for pointer arrays). out: `rax` = pointer.

Both are **fatal on error** (arena exhaustion): a fixed stderr message,
`exit(2)`.

### 4.5 Node kinds — top-level declarations

| `kind` | `a` | `b` | `c` | `d` |
|---|---|---|---|---|
| `AST_PARAM` | `name_offset` | `name_len` | `type` (ptr) | — |
| `AST_FIELD_DECL` | `name_offset` | `name_len` | `type` (ptr) | — |
| `AST_SIGNATURE` | `name_offset` | `name_len` | `params` (ptr to arena array) | `param_count` |
| `AST_STRUCT_DECL` | `name_offset` | `name_len` | `fields` (ptr to arena array) | `field_count` (≥1) |
| `AST_FUNCTION` | `signature` (ptr) | `return_type` (ptr, 0 = `void`) | `body` (`AST_FUNC_BLOCK` ptr) | — |
| `AST_EXTERN_DECL` | `signature` (ptr) | `return_type` (ptr, 0 = `void`) | — | — |
| `AST_PROGRAM` | `decls` (ptr to arena array) | `decl_count` (≥1) | — | — |

**Why is there a separate `AST_SIGNATURE` node, instead of `AST_FUNCTION`
containing everything directly?** `function` and `extern_decl` literally
share the `identifier "(" params? ")"` portion in the grammar. A `function`
would need 6 fields' worth of useful data: name (offset+len = 2 fields,
because the codebase convention is that name storage is never a copy of the
spelling, but always a re-slice of the source — see 4.1) + the `params`
*list* (ptr+count = 2 fields, since the actual number of parameters can be
anything — the 3 parameters of `sys_write` and the 6 of `sys_mmap` both
collapse to the same "ptr, count" pair after parsing) + `return_type` (1) +
`body` (1). That is more than the four generic fields allow. Rather than
solve this with ad hoc packing, we factored out the common prefix into a
standalone `AST_SIGNATURE` node — the same principle by which
`AST_ASSIGN_PAIR`/`AST_FIELD_INIT` also factor the shared shape out of
larger structures. `AST_FUNCTION` and `AST_EXTERN_DECL` thus need only 2–3
fields (`signature` ptr + `return_type` ptr, plus `body` ptr for
`AST_FUNCTION`), and the decomposition mirrors the EBNF's own common-prefix
factoring rather than fighting it. `return_type` uses the same "0 = absent"
convention as the expression of `STMT_RETURN`, the initializer of `DECL`, or
the `else` branch of `STMT_IF` — `0` means `void`, since `void` is not a
member of the `type` rule and thus cannot be confused with an actual type
pointer.

**`AST_PARAM` and `AST_FIELD_DECL` are structurally identical** (both are
just "name : type"), yet remain two separate `kind`s — because they are two
separate grammar rules, in mutually independent contexts (function signature
vs. struct body), with different future semantic roles (calling convention
vs. field layout). Same rationale by which `AST_DECL_MUT`/`AST_DECL_CONST`
also remained two separate `kind`s despite their nearly identical shape.

---

## 5. Token lookahead (`parser_tokens.asm`)

`lex_next` returns a single token per call, with an explicit cursor. The
parser needs **2-token lookahead** — no more, no less — because the grammar
has exactly two places that need to look at "the token after the current
token" without consuming it:

1. Disambiguating pointer-array in the type grammar.
2. Distinguishing `struct_literal` from a bare `identifier` in `primary`.

```nasm
tok_cur:        resb TOKEN_SIZE   ; 32 bytes, from tokens.inc
tok_peek:       resb TOKEN_SIZE
tok_peek_valid: resq 1
raw_cursor:     resq 1             ; lex_next's own byte-offset cursor
```

- **`parser_init`** (in: `rdi`=source buffer, `rsi`=start offset,
  `rdx`=length): sets up the globals, calls `parser_advance` once.
- **`parser_advance`**: if `tok_peek_valid`, copies 32 bytes
  `tok_peek`→`tok_cur`; otherwise calls `lex_next` directly into `tok_cur`.
- **`parser_peek`**: if `!tok_peek_valid`, calls `lex_next` into `tok_peek`;
  **does not consume**. Out: `rax` = address of `tok_peek`.
- **`parser_expect`** (in: `rdi`=expected `TOK_*` kind, `rsi`/`rdx`=error
  message): if it doesn't match, `report_parse_error`; otherwise
  `parser_advance`.

---

## 6. Type parser (`type_parser.asm`)

`token_starts_base_type(kind)`: `kind == TOK_IDENT`, or `TOK_KW_INT8 <= kind
<= TOK_KW_BOOL` (the 22–32 range in `tokens.inc`).

`parse_type` — decides purely based on `tok_cur.kind`, **with no
backtracking**:

- **`TOK_STAR`**: consumes. If `token_starts_base_type(tok_cur)` **and**
  `parser_peek().kind == TOK_LBRACKET`: `base_type` → `AST_TY_POINTER` →
  `[ INT ]` → `AST_TY_ARRAY{elem=pointer_node, count=N}` (the default "array
  of N pointers" form). Otherwise: recursively `parse_type` on the operand,
  `AST_TY_POINTER{inner}` (also covers the `*(T[N])` case).
- **`TOK_LPAREN`**: consumes, recursively `parse_type`, expects `)`, returns
  without wrapping.
- **`token_starts_base_type`**: `base_type`; if `[` follows, `AST_TY_ARRAY`;
  otherwise unchanged.
- otherwise: `report_parse_error("expected type")`.

---

## 7. Expression parser (`expr_parser.asm`)

**One grammar level = one routine**, a direct translation of the EBNF chain
(not Pratt/precedence climbing).

The chain: `parse_logic_or` → `parse_logic_and` → `parse_comparison` →
`parse_bit_or` → `parse_bit_xor` → `parse_bit_and` → `parse_shift` →
`parse_additive` → `parse_multiplicative` → `parse_unary` → `parse_postfix`
→ `parse_primary`. Every binary level (except `comparison`) is a `while`
loop.

**`parse_comparison`** is the sole exception — `if`, not `while` (a literal
translation of the grammar's `?` marker; a second comparison operator is
left unconsumed and fails at the driver's trailing EOF check — this is the
intended mechanism, not a shortcoming).

**`parse_unary`** (right-to-left associative prefix chain, `! - * &`).

**`parse_postfix`** (left-to-right associative suffix loop: `[expr]` →
`AST_EX_INDEX`, `.identifier` → `AST_EX_FIELD`, `(args?)` → `AST_EX_CALL`).

**`parse_primary`**: for `TOK_IDENT`, `parser_peek`; if `{` follows,
`parse_struct_literal`; otherwise `AST_EX_IDENT`. `TOK_INT`/`TOK_KW_TRUE`/
`TOK_KW_FALSE`/`TOK_KW_NULL`/`TOK_LPAREN`/`TOK_LBRACE` go to the
corresponding branch.

---

## 8. Variable-arity lists

`call` arguments, the `struct_literal` field list, the `array_literal`
element list, the `assign_stmt` pair list, the `block`/`func_block`
statement list, the `func_block` declaration list — and, newly in this pass,
the `params` parameter list, the `struct_decl` field list (`field_decl+`),
and the `program` declaration list (`top_level_decl+`) — all follow the same
pattern, without dynamic memory allocation:

1. Reserve `MAX_LIST_ARITY*8` bytes on the **machine stack** (`sub rsp,
   ...`).
2. Parse elements one by one, writing each pointer into the stack scratch
   area.
3. On close, `ast_alloc_bytes(count*8)` in the arena, then an exact-size
   copy there.
4. Release the stack scratch area (`add rsp, ...`).

**Why the stack, and not a shared global scratch buffer?** The second
element of an array literal like `{1, mult(4), 9}` is itself a function call
with its own argument list — native stack recursion (every nested
list-parse gets its own fresh, `rsp`-relative scratch region) solves this
for free.

Per-list arity requirements:
- `parse_call_args`, `parse_params`: 0 is allowed (`args ::= expr_list?`,
  `params ::= param ("," param)*` via the caller-side `params?`) —
  comma-separated, empty case allowed without checking.
- `parse_array_literal`, struct-literal field list: **at least 1** is
  required, comma-separated.
- `assign_stmt` pair list: no explicit "empty list" branch — structurally
  guaranteed to have at least 1 (see 4.3).
- `block` (`stmt*`) and the `func_block` declaration list (`decl*`): **0 is
  allowed** — there is no "at least 1" check, because the grammar has only
  `*` here, not `+`.
- `func_block` runs **two consecutive** (not nested) variable-arity lists
  over the same stack scratch region: the declaration list is fully closed
  out (arena commit + `rsp` release) before the statement list's scratch is
  allocated — no time overlap, hence no conflict.
- The `struct_decl` field list (`field_decl+`) and the `program` declaration
  list (`top_level_decl+`): **at least 1** required, but **no
  comma-separator** — each element terminates itself (`field_decl` via its
  own `;`, `top_level_decl` via its grammatical structure), so the loop
  condition is "check the closing token (`}` / `EOF`) after every element,"
  not "check for a comma." The empty case is checked up front with a
  dedicated error message — the same pattern as the "at least 1" check for
  `array_literal`/`struct_literal` — rather than relying on an automatic
  fall-through into the `func_block` decl/stmt-ordering error (see 9.2 and
  10.4): there, a lower-precedence rule existed to fall through to; here
  there is none.

---

## 9. Statement and declaration parser (`stmt_parser.asm`)

### 9.1 Distinguishing `assign_stmt` / `expr_stmt`

The `assign_stmt` and `expr_stmt` alternatives of the `stmt` grammar can
begin with the same tokens — `lvalue` and `expr` fully overlap at the very
start (both can begin with `*` or an identifier). The formal grammar defines
`lvalue` as its own, narrower rule (no calls, no binary operators, no
literals — just a `*`-prefix chain and identifier+index/field suffixes).

Choosing between two solutions:

- **A dedicated `parse_lvalue` that strictly follows the `lvalue` grammar.**
  Rejected: for something like `mult(4);` (an `expr_stmt`), a truly strict
  `parse_lvalue` would consume `mult` and then stop at the `(` (the call
  suffix is not in the `lvalue` grammar) — recovering from there would
  require either backtracking, or `parse_lvalue` would have to reimplement
  the `parse_postfix`/`parse_unary` logic anyway as a fallback. That would
  mean more code and a larger bug surface for the benefit (rejecting
  `1 + 2 := 3;` at parse time) that the project had already deliberately
  deferred to the semantic phase elsewhere (struct-literal field
  completeness, based-form digit-range).
- **Always call the existing `parse_expr()` first, then branch on
  `tok_cur.kind == TOK_ASSIGN`.** *This is the chosen solution.* `TOK_ASSIGN`
  (`:=`) does not appear in any of `expr`'s operator sets (neither the
  binary levels, nor `unary`/`postfix`), so `parse_expr()` is guaranteed to
  stop exactly before a `:=` if one follows — verified by hand by tracing
  `a[0] := 5;` and `*p := *p + 1;` through the full precedence chain. Zero
  new mechanism, zero backtracking. More permissive than the formal grammar
  (e.g. `1 + 2 := 3;` is syntactically accepted, with rejection left to the
  semantic phase) — the same pattern the project has already deliberately
  applied multiple times.

For this reason, **there is no separate `parse_lvalue` routine, and no
separate node kind for `lvalue`** — see 4.3.

### 9.2 `parse_stmt` — dispatcher

```
parse_stmt:
    tok_cur.kind == TOK_KW_IF     -> parse_if_stmt      (tail call)
    tok_cur.kind == TOK_KW_WHILE  -> parse_while_stmt    (tail call)
    tok_cur.kind == TOK_KW_RETURN -> parse_return_stmt   (tail call)
    otherwise                     -> parse_assign_or_expr_stmt (tail call)
```

**This makes it automatic — rather than a separate check — that "`decl` may
only appear before the `stmt*` of `func_block`":** `parse_stmt` has no
`TOK_KW_MUT`/`TOK_KW_CONST` branch, so a stray `mut`/`const` lands on the
`parse_assign_or_expr_stmt` → `parse_expr` → `parse_primary` chain, which
also has no such branch, and produces an `"expected expression"` error —
this is a direct consequence of the fact that `func_block`'s declaration
loop only calls `parse_decl` for as long as `tok_cur` is `mut`/`const`; no
extra check is needed.

### 9.3 `parse_assign_or_expr_stmt`

```
node = parse_expr()
if tok_cur.kind != TOK_ASSIGN:
    parser_expect(TOK_SEMI, "expected ';'")
    return ast_alloc_node(AST_STMT_EXPR){a=node}

; assign_stmt: node is the first lvalue
pairs = []
loop:
    parser_expect(TOK_ASSIGN, "expected ':='")   ; consumes the ':=' (including the first one, for consistency)
    rhs = parse_expr()
    pairs.append(ast_alloc_node(AST_ASSIGN_PAIR){a=node, b=rhs})
    if tok_cur.kind != TOK_COMMA: break
    parser_advance()                              ; ','
    node = parse_expr()                            ; next lvalue
commit pairs -> arena (see chapter 8)
parser_expect(TOK_SEMI, "expected ';'")
return ast_alloc_node(AST_STMT_ASSIGN){a=pairs_ptr, b=count}
```

### 9.4 `parse_decl`

```
decl ::= ("mut" | "const") identifier ":" type (":=" expr)? ";"
```

Selects the `kind` (`AST_DECL_MUT`/`AST_DECL_CONST`) from the `mut`/`const`
keyword, consumes it, expects the identifier (`name_offset`/`name_len`),
`:`, `parse_type()`, an optional `:=` + `parse_expr()` (`init` = 0 if
absent), `;`. The registers that stay live between parsing the type and the
initializer (`kind`, `name_offset`, `name_len`) are protected by the
caller's own frame (push/pop at the start/end of the routine) — the same
discipline used in the expression parser.

### 9.5 `parse_if_stmt`, `parse_while_stmt`, `parse_return_stmt`

```
if_stmt    ::= "if" "(" expr ")" block ("else" block)?
while_stmt ::= "while" "(" expr ")" block
return_stmt ::= "return" expr? ";"
```

`if`/`while`: expects `(` `expr` `)`, then `parse_block()` (and, for `if`,
an optional `else` + another `parse_block()`). `return`: if `tok_cur ==
TOK_SEMI` directly after the `return` keyword, there is no expression
(`value` = 0) — no lookahead is needed, the `;` is unambiguous on its own.

### 9.6 `parse_block`, `parse_func_block`

```
block      ::= "{" stmt* "}"
func_block ::= "{" decl* stmt* "}"
```

`parse_block`: the opening `{` is checked with an **explicit
`parser_expect(TOK_LBRACE, ...)`**, not a bare `parser_advance` — the
language has **no** brace-less, single-statement block alternative (e.g.
`if (a == b) return;` is a syntax error, not a shorthand for a
single-statement block). It then loops calling `parse_stmt()` until
`tok_cur != TOK_RBRACE`, then `}`. Zero statements is also valid (no "at
least 1" check). The lack of an explicit check (a bare `parser_advance`,
which would have unconditionally swallowed `tok_cur`, whatever it was) used
to lead to a silent, misleading error path — see the "gap-vs-bug" note in
9.7.

`parse_func_block`: after `{`, **first** a loop for as long as `tok_cur` is
`mut`/`const` (each parsed with `parse_decl`), **then** a loop just like
`parse_block` (`parse_stmt`, until not `}`), then `}`. The two lists use the
stack scratch area sequentially, not nested (see chapter 8).

### 9.7 Bug classes uncovered while implementing this slice

While writing this slice, three previously hidden issues surfaced in the
**already-existing** type/expression parser and AST-dump code — each stayed
hidden until now because the EARLIER call sites happened to never trigger
the buggy behavior. All three were fixed; each lesson is worth recording
explicitly, because a future extension could fall into the same trap:

1. **Missing register protection in "leaf" branches.** The
   `.ident_or_struct`/`.int` branches of `parse_primary`, and several
   branches of `parse_type`/`parse_base_type`, wrote directly to the
   `r12`/`r13`/`r14` registers without push/pop protection — this did not
   cause a bug as long as no caller kept live state in them across a nested
   call. The `assign_stmt` pair list (which keeps the current `lvalue` in
   `r12` while parsing the RHS via another `parse_expr()` call) was the
   first caller to actually require this — and it failed exactly there,
   with a segmentation fault. **Rule reinforced by this:** every routine
   that uses `r12`–`r15`/`rbx` for internal purposes **must** push/pop them
   at the start/end of its own frame — regardless of whether CURRENT callers
   require it, because a FUTURE caller might.
2. **Reuse of `rax` after it was overwritten by an `emit_str` call.**
   Several "optional child" patterns in `ast_dump.asm` (the `else` branch of
   `if`, the expression of `return`) wrote the pattern as `rax = [node +
   field]; cmp rax,0; if not 0: emit_str (emit separator space); mov
   rdi,rax; dump_*` — but the `emit_str` call **overwrites `rax`**
   (caller-saved register, as elsewhere), so the subsequent `mov rdi, rax`
   ended up using the wrong (leftover from `emit_str`'s internal
   computation) value. **Fix:** after the `emit_str` call, the field must be
   **re-read** from the node (`mov rdi, [node+field]`), never relying on the
   previously loaded `rax`.
3. **Missing `'{'` check in `parse_block` ("gap-vs-bug").** `parse_block`
   originally consumed the opening `'{'` with an unconditional
   `parser_advance`, instead of `parser_expect` — neither this routine nor
   its callers (`parse_if_stmt`, `parse_while_stmt`) checked beforehand that
   `tok_cur` was actually `TOK_LBRACE`. This did not crash (not undefined
   behavior, unlike points 1–2), it merely **swallowed** whatever `tok_cur`
   was, and reported the error (if any) at a much more confusing, misleading
   location — e.g. for `if (a == b) return;`, the error originally produced
   was `"expected expression"` at the `;`, not `"expected '{'"` at `return`.
   An explicit user decision settled this: the language has **no**
   brace-less, single-statement block alternative — the `'{'` of the
   `block ::= "{" stmt* "}"` grammar rule is always mandatory, never
   optional. **Fix:** at the start of `parse_block`,
   `parser_expect(TOK_LBRACE, "expected '{'")`, instead of `parser_advance`
   (see 9.6, and fixtures 35–37).

---

## 10. Top-level declaration parser (`top_parser.asm`)

```ebnf
program        ::= top_level_decl+
top_level_decl ::= function | struct_decl | extern_decl

struct_decl    ::= "struct" identifier "{" field_decl+ "}"
field_decl     ::= identifier ":" type ";"

function       ::= "function" identifier "(" params? ")" ":" return_type func_block
return_type    ::= type | "void"
extern_decl    ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
params         ::= param ("," param)*
param          ::= identifier ":" type
```

This set of routines checks only the **grammatical shape** — semantic
constraints (extern-name whitelist, struct-field completeness, matching
return type against expression type, unused-return-value warnings) are all
left for a future semantic-analysis phase, the same "the parser allows, the
semantics rejects" principle the project has already applied consistently.
**Also out of scope for this pass** is forward declaration of a `function`
without a body (item 6 of "decisions deferred to later" in the main spec) —
a separate, deferred grammar extension distinct from `extern function`.

### 10.1 `parse_param`, `parse_params`, `parse_signature`, `parse_return_type`

The machinery shared by `function` and `extern_decl`, so this is built
first:

- **`parse_param`** (`identifier ":" type`) — `r12`/`r13` =
  `name_offset`/`name_len`, `r14` = the result of `parse_type()`; builds an
  `AST_PARAM` node. Same shape as `parse_field_init` in `expr_parser.asm`.
- **`parse_params`** (`param ("," param)*`, i.e., from the caller's
  perspective the full `params?` — zero or more) — structurally identical
  to `parse_call_args` in `expr_parser.asm`: `TOK_RPAREN` is checked up
  front for the empty case (not an error — `params` is optional), otherwise
  a comma-separated loop with `parse_param`. `rax` = array ptr (0 if empty),
  `rdx` = element count — the same two-return-value convention as
  `parse_call_args`, because the raw `params` payload belongs to
  `AST_SIGNATURE`, not to a standalone node.
- **`parse_signature`** (`identifier "(" params? ")"`) — `r12`/`r13` = name
  offset/len, `r14`/`r15` = the ptr/count result of `parse_params`; builds
  an `AST_SIGNATURE` node. Literally shared between `parse_function` and
  `parse_extern_decl` — this is the direct payoff of factoring out the
  node.
- **`parse_return_type`** (`type | "void"`) — trivial: if `tok_cur.kind ==
  TOK_KW_VOID`, consumes and returns `0`; otherwise tail-calls `parse_type`.
  Has no node of its own — same "0 = absent" idiom.

### 10.2 `parse_function`, `parse_extern_decl`

```
function ::= "function" identifier "(" params? ")" ":" return_type func_block
```

`r12` = the result of `parse_signature()`, `r13` = the result of
`parse_return_type()` (0 = `void`), `r14` = the result of
`parse_func_block()` (the routine extracted from `stmt_parser.asm`, already
handling the `"{" decl* stmt* "}"` body). `:` is mandatory between the
signature and the `return_type` (`parser_expect`).

```
extern_decl ::= "extern" "function" identifier "(" params? ")" ":" return_type ";"
```

`r12`/`r13` = signature/return_type-or-0. After `"extern"`, it explicitly
checks for and consumes the `"function"` keyword (with its own error
message if absent — `extern` alone means nothing in this grammar), followed
by the same `parse_signature`/`parse_return_type` chain as `function`, with
a closing `;` (no body).

### 10.3 `parse_field_decl`, `parse_struct_decl`

```
struct_decl ::= "struct" identifier "{" field_decl+ "}"
field_decl  ::= identifier ":" type ";"
```

`parse_field_decl` is identical to `parse_param`, plus a closing
`parser_expect(TOK_SEMI)`; builds an `AST_FIELD_DECL` node.
`parse_struct_decl`: consumes `"struct"` + the name, `parser_expect
(TOK_LBRACE)`, then the `field_decl+` (at least 1, **no** comma-separator —
each `field_decl` terminates with its own `;`, so the loop condition is
"check for `}` AFTER every element," not "check for a comma BEFORE it,"
unlike the comma-separated lists of `params`/`args`/`array_literal`) — the
same empty-list-checked-up-front pattern as
`parse_array_literal`/`parse_struct_literal`, with a dedicated message
(`"struct declaration requires at least one field"`).

### 10.4 `parse_top_level_decl`, `parse_program`

```
top_level_decl ::= function | struct_decl | extern_decl
```

A pure dispatcher, tail calls only (same shape as `parse_stmt`):
`TOK_KW_FUNCTION` → `parse_function`, `TOK_KW_STRUCT` →
`parse_struct_decl`, `TOK_KW_EXTERN` → `parse_extern_decl`, otherwise
`report_parse_error("expected top-level declaration")`. Unlike `parse_stmt`,
there is **no** lower-precedence rule to fall through to on a non-matching
token here, so — unlike the `func_block` decl/stmt-ordering error (see
9.2) — this needs its own, explicit error message.

```
program ::= top_level_decl+
```

`r12` = element count, `r13` = arena target: the same one-or-more pattern as
the `parse_struct_decl` field list (empty case checked up front, with a
dedicated message: `"program requires at least one top-level declaration"`),
looping with `parse_top_level_decl` until `TOK_EOF`. It does **not** consume
the `EOF` itself — the driver's own trailing
`parser_expect(TOK_EOF, ...)` check, identical for every directive, handles
that uniformly.

### 10.5 Export convention

Every top-level routine in `top_parser.asm` is `global` — the same
"every routine exported" convention as `type_parser.asm`/`expr_parser.asm`/
`stmt_parser.asm` (only `ast_dump.asm` exports minimally, because its helper
routines never cross the file boundary there).

---

## 11. Error handling and diagnostics

Extends (does not duplicate) the lexer's existing `err_buf`/`err_append_*`/
`compute_line_col` infrastructure (`runtime.asm`). `report_parse_error` (in:
`rsi`/`rdx` = message), in `parser_tokens.asm`: builds into `err_buf` the
line `parse error: <message> at line L, col C (byte offset O), found
<token-description>`, writes it to stderr, `exit(1)`.

**Exit code: `1`**, the same category as a lexical error. `exit(2)` is
reserved exclusively for resource-type errors (arena exhaustion,
syscall failure).

There is no `flush_out` call before an error — the parser only writes the
AST dump after a **fully successful** parse.

---

## 12. AST dump format

A single-line, fully parenthesized S-expression, terminated with `\n`,
re-slicing the source text wherever possible.

**Type dump** (`dump_type`):

| `kind` | Emitted form |
|---|---|
| `AST_TY_BASE` | `(base <spelling>)` |
| `AST_TY_POINTER` | `(ptr <inner>)` |
| `AST_TY_ARRAY` | `(array <inner> <N>)` |

**Expression dump** (`dump_expr`):

| `kind` | Emitted form |
|---|---|
| `AST_EX_INT` | `(int <value>)` — the computed decimal value, not the raw source spelling |
| `AST_EX_BOOL` | `(bool true)` / `(bool false)` |
| `AST_EX_NULL` | `(null)` |
| `AST_EX_IDENT` | `(ident <name>)` |
| `AST_EX_UNARY` | `(unary <symbol> <operand>)` |
| `AST_EX_BINARY` | `(binary <symbol> <left> <right>)` |
| `AST_EX_INDEX` | `(index <base> <index>)` |
| `AST_EX_FIELD` | `(field <base> <name>)` |
| `AST_EX_CALL` | `(call <callee> <arg0> <arg1> ...)` |
| `AST_EX_STRUCT_LIT` | `(struct <TypeName> (field <name0> <value0>) ...)` |
| `AST_EX_ARRAY_LIT` | `(array_lit <elem0> <elem1> ...)` |

**Statement/declaration dump** (`dump_stmt`, `dump_decl`,
`dump_func_block`):

| `kind` | Emitted form |
|---|---|
| `AST_DECL_MUT` | `(decl_mut <name> <type>)`, with a trailing `<init>` if present |
| `AST_DECL_CONST` | `(decl_const <name> <type>)`, with a trailing `<init>` if present |
| `AST_ASSIGN_PAIR` | `(pair <lvalue> <rhs>)` — internal helper, reachable only through `dump_node_list`, following the `dump_field_init` pattern |
| `AST_STMT_ASSIGN` | `(assign <pair0> <pair1> ...)` |
| `AST_STMT_IF` | `(if <cond> <then_block>)`, with a trailing `<else_block>` if present |
| `AST_STMT_WHILE` | `(while <cond> <body_block>)` |
| `AST_STMT_RETURN` | `(return)` or `(return <expr>)` |
| `AST_STMT_EXPR` | `(expr_stmt <expr>)` — deliberately not a bare `<expr>` re-emission, so that a dump produced with the `STMT` directive is visibly distinguishable from an `EXPR`-directive dump of the same text |
| `AST_BLOCK` | `(block <stmt0> <stmt1> ...)` — internal helper (`dump_block`), used by `if`/`while` |
| `AST_FUNC_BLOCK` | `(func_block (decls <decl0> ...) (stmts <stmt0> ...))` — its own two-list dump, calling `dump_node_list` twice |

A missing optional child (a decl's initializer, an `if`'s `else` branch, a
`return`'s expression) is simply omitted — the same convention as the dump
of a zero-argument call.

Operator symbols come from an `op_symbol_labels` table, indexed by `kind -
TOK_ASSIGN` (60–79 range).

**Top-level dump** (`dump_top_level_decl`, `dump_program`):

| `kind` | Emitted form |
|---|---|
| `AST_PARAM` | `(param <name> <type>)` — internal helper, only through `dump_node_list`, following the `dump_field_init` pattern |
| `AST_FIELD_DECL` | `(field_decl <name> <type>)` — same role, for struct bodies |
| `AST_FUNCTION` | `(function <name> (params <p0> ...) <return_type> <func_block-dump>)` |
| `AST_EXTERN_DECL` | `(extern_decl <name> (params <p0> ...) <return_type>)` |
| `AST_STRUCT_DECL` | `(struct_decl <name> (fields <f0> ...))` |
| `AST_PROGRAM` | `(program <decl0> <decl1> ...)` |

`<return_type>` is the bare word `void` (no parentheses — a keyword atom,
not a compound node; every real `type` dump always starts with `(`, so there
is no ambiguity) if the pointer is 0, otherwise it goes through the existing
`dump_type` — factored into a small internal `dump_return_type` helper, the
same way `dump_block` is shared between the `if`/`while` branches of
`dump_stmt`.

Only **`dump_top_level_decl`** and **`dump_program`** are `global`-exported
— following exactly the `dump_stmt` pattern: `dump_top_level_decl` is a
single routine with nested `.function`/`.struct_decl`/`.extern_decl` label
targets (not three separately named dump routines), the same shape
`dump_stmt` uses for its five statement kinds. `dump_param`/
`dump_field_decl`/`dump_return_type` stay internal, as do
`dump_field_init`/`dump_block`/`dump_assign_pair`. Every new field read
AFTER an `emit_str` call re-reads from `[rbx + field]`, never relying on a
previously loaded register — see 9.7, the lesson from the `emit_str`-`rax`
bug found in the previous pass.

---

## 13. Test suite

`Hoare/tests/parser_cases/` directory, the 3-file convention (`.ptl` /
`.expected.stdout` / `.expected.stderr` / `.expected.exit`), every `.ptl`
fixture's **first line is a directive**.

| Fixture | Content | Expected output |
|---|---|---|
| `01_type_simple_base` | `TYPE` / `int32` | `(base int32)` |
| `02_type_pointer_array` | `TYPE` / `*Node[3]` | `(array (ptr (base Node)) 3)` |
| `03_type_paren_pointer_to_array` | `TYPE` / `*(int32[10])` | `(ptr (array (base int32) 10))` |
| `04_expr_precedence` | `EXPR` / `1 + 2 * 3 - 4 / 2` | full tree, per precedence |
| `04b_expr_bitwise_vs_comparison` | `EXPR` / `e & 1 == 1` | `&` binds tighter than `==` |
| `05_expr_struct_literal` | `EXPR` / `Pair { a := 8, b := 15 }` | `(struct Pair (field a (int 8)) (field b (int 15)))` |
| `06_expr_array_literal` | `EXPR` / `{1, 2, 3}` | `(array_lit (int 1) (int 2) (int 3))` |
| `07_expr_postfix_chain` | `EXPR` / `arr[0].next(1, 2)` | mixed index/field/call chain |
| `08_expr_syntax_error` | `EXPR` / `a < b < c` | empty stdout, `exit(1)`, stderr about the unconsumed `<` |
| `13_decl_mut_with_init` | `DECL` / `mut x : int32 := 5;` | basic mut decl |
| `14_decl_const` | `DECL` / `const total : uint := 100;` | const decl |
| `15_decl_mut_no_init` | `DECL` / `mut n : int32;` | omitted initializer |
| `16_stmt_expr_call` | `STMT` / `mult(4);` | `expr_stmt` — the non-`:=` branch of the split |
| `17_stmt_assign_single` | `STMT` / `x := 5;` | the `:=` branch of the split, single pair |
| `18_stmt_assign_multi` | `STMT` / `a := b, b := a;` | Dijkstra swap, simultaneous assignment |
| `19_stmt_assign_deref_lvalue` | `STMT` / `*p := *p + 1;` | `lvalue`'s `"*" lvalue` form |
| `20_stmt_if_else` | `STMT` / `if (x > 0) { y := 1; } else { y := 2; }` | nested block dump, both branches |
| `21_stmt_while` | `STMT` / `while (e > 0) { e := e - 1; }` | while + block |
| `22_stmt_return_value` | `STMT` / `return x + 1;` | return with an expression |
| `23_stmt_return_void` | `STMT` / `return;` | return without an expression |
| `24_func_block_full` | `FUNC_BLOCK` / a body resembling the main spec's `is_even` | `decl*` + `stmt*` together |
| `25_func_block_decl_after_stmt_error` | `FUNC_BLOCK` / `{ mut x : int32 := 1; x := 2; mut y : int32 := 3; }` | the decl-placement rule fails via the `"expected expression"` path, no separate check |
| `26_top_level_struct_single_field` | `TOP_LEVEL_DECL` / `struct Node { value : int32; }` | struct_decl, one field |
| `27_top_level_struct_multi_field` | `TOP_LEVEL_DECL` / `struct Point { x : int32; y : int32; }` | struct_decl, multiple fields |
| `28_top_level_struct_empty_error` | `TOP_LEVEL_DECL` / `struct Empty { }` | `field_decl+` empty-list rejection |
| `29_top_level_function_void_no_params` | `TOP_LEVEL_DECL` / `function noop() : void { return; }` | empty `params?`, `void` return_type |
| `30_top_level_function_with_params` | `TOP_LEVEL_DECL` / `function add(a: int32, b: int32) : int32 { return a + b; }` | parameter list, non-`void` return_type |
| `31_top_level_extern_with_params` | `TOP_LEVEL_DECL` / `extern function sys_write(fd: int64, buf: *uint8, count: uint64) : int64;` | extern_decl, pointer-typed parameter, the main spec's own whitelist example |
| `32_top_level_extern_void` | `TOP_LEVEL_DECL` / `extern function sys_exit(code: int64) : void;` | extern_decl, `void` return_type |
| `33_program_struct_and_function` | `PROGRAM` / a `struct` followed by a `function` that uses it | `program`'s `top_level_decl+`, multiple declarations, cross-declaration field access |
| `34_program_empty_error` | `PROGRAM` / empty input | `top_level_decl+` empty-list rejection |
| `35_stmt_if_missing_braces_error` | `STMT` / `if (a == b) return;` | `parse_block`'s explicit `'{'` check (see 9.7/3) |
| `36_stmt_while_missing_braces_error` | `STMT` / `while (a == b) return;` | same, on the `while` branch |
| `37_stmt_if_else_missing_braces_error` | `STMT` / `if (a == b) { return; } else return;` | same, on the `else` branch's `parse_block` call |
| `38_expr_lex_error_bad_char` | `EXPR` / `1 + =` | `TOK_ERROR` (length 1) description in "found": `invalid character '='` (see 16.3) |
| `39_expr_lex_error_based_form_empty` | `EXPR` / `16n` | `TOK_ERROR` (length 0) description: `invalid token` |
| `40_expr_lex_error_unterminated_comment` | `EXPR` / `1 + /* oops` | `TOK_ERROR_COMMENT` description: `unterminated comment` |

The exact stderr text and position numbers are always recorded from the
actual output of the compiled binary — never invented by hand.

---

## 14. Driver (`parser_main.asm`)

Directive-line recognition: the length and content of the span up to the
first `\n` is compared against every known directive (`TYPE`, `EXPR`,
`DECL`, `STMT` — all 4 bytes —, `PROGRAM` — 7 bytes —, `FUNC_BLOCK` — 10
bytes —, and `TOP_LEVEL_DECL` — 14 bytes). Since directives can have
different lengths, a generic `bytes_equal(ptr1, ptr2, len)` helper performs
the comparison, checking the length first for each candidate and only then
the content.

The position after the `\n` gives the actual start offset for parsing,
which is passed to `parser_init`. After a successful parse, the driver
**always** calls `parser_expect(TOK_EOF, "expected end of input")`. Then the
appropriate `dump_*` is called based on the kind, followed by `flush_out`,
`exit(0)`. There is no separate `BLOCK` directive — the `block` rule only
occurs inside `if`/`while`/`func_block`, already covered through those.
Likewise, there is **no** separate directive per `function`/`struct_decl`/
`extern_decl` — the single `TOP_LEVEL_DECL` directive covers all three via
the `parse_top_level_decl`/`dump_top_level_decl` dispatcher, with the
fixture's source text selecting which branch gets exercised — the same
pattern by which a single `STMT` directive covers all five statement kinds.

---

## 15. Implementation order — top-level declarations

0. Add the 7 new `AST_*` constants to `ast.inc`
   (`AST_PARAM`..`AST_PROGRAM`, see 4.5).
1. `parse_param` / `parse_params` / `parse_signature` / `parse_return_type`
   — the shared machinery, written and verified first, because both
   `function` and `extern_decl` build on it.
2. `parse_function` + `parse_extern_decl` + `parse_top_level_decl` (for now
   only the function/extern branches). `dump_param`, `dump_return_type`,
   `dump_top_level_decl` (function/extern cases). Wiring in the
   `TOP_LEVEL_DECL` directive. Fixtures 29–32. **Gate.**
3. `parse_field_decl` + `parse_struct_decl`, extending `parse_top_level_decl`'s
   struct branch + the struct case of `dump_top_level_decl` +
   `dump_field_decl`. Fixtures 26–28. **Gate.**
4. `parse_program` + `dump_program`; the `PROGRAM` directive. Fixtures
   33–34. **Gate.**
5. Full regression: all 34 parser fixtures + 6 lexer fixtures in a single
   `docker build`. Green on the first try — no new register-protection or
   `emit_str`-side-effect bug surfaced in this pass (consistent adherence
   to the two rules recorded in 9.7 was checked for every new routine while
   writing it, not debugged after the fact).
6. Update `Hoare/README.md` (directive table, dump-form example, Layout
   section).
7. Retroactive fix, at user request: patching `parse_block`'s missing `'{'`
   check (`parser_expect`, see 9.6/9.7-3) — the language has no
   brace-less block alternative, and the parser must enforce this too, not
   only the formal grammar. Fixtures 35–37. Full regression: 37 parser
   fixtures + 6 lexer fixtures, green.
8. Adding the black-box test suite (see chapter 16), then — in response to
   a gap observed there, at user request — improving `TOK_ERROR`/
   `TOK_ERROR_COMMENT` diagnostic quality in both binaries
   (`err_append_token_desc` in the parser, `report_error` in the lexer, see
   16.3). Parser fixtures 38–40 + lexer-spec fixture 7
   (`07_based_form_empty_digits`). Full regression: 40 parser fixtures + 24
   black-box fixtures + 7 lexer fixtures, green.

With this, the **entire** Stage 0 EBNF grammar is covered by the
`build/parser` binary — from the `program` rule down to the deepest
expression level. There is no further deliberately deferred parser slice;
the remaining open items (forward-declared functions without a body,
extern-whitelist/type-matching semantic checks, LLVM IR code generation) all
belong to a future semantic-analysis/code-generation phase, not to the
parser.

---

## 16. Black-box test suite (`tests/blackbox_cases/`, `run_blackbox_tests.sh`)

The test suite of chapters 1–15 (`tests/parser_cases/`) is **white-box** in
nature: every fixture is tailored to a specific grammar rule (the directive
selects which `parse_*` routine gets exercised), and the goal is isolated
coverage of that routine. This second, separate suite treats `build/parser`
as a **black box**: every fixture is a complete, self-contained `PROGRAM`
that implements a real programming task (rather than demonstrating a
grammar construct), and it examines only observable behavior (exit code,
stdout, stderr) — it does not care which internal routine runs to produce
it.

### 16.1 The chosen tasks — programming "theorems"

The classic Fóthi Ákos-style programming-methodology "theorems" (see the
"Design decisions" chapter of the main spec regarding the origin of the
`:=` notation) — each got **at least one correct and one incorrect**
program, with varied, genuinely occurring kinds of errors (never the same
error class twice):

| Fixture pair | Theorem | The faulty version's bug |
|---|---|---|
| `01`/`02` | Summation | missing `;` |
| `03`/`04` | Counting | `=` instead of `:=` (a lexical error, not just a syntactic one) |
| `05`/`06` | Decision (with early `return`) | missing `)` in the condition |
| `07`/`08` | Selection (index/position) | misspelled keyword (`retrun`) |
| `09`/`10` | Maximum-selection | missing `}` (unbalanced block) |
| `11`/`12` | Filtering (two output pointer parameters) | missing `)` in a `*(T[N])` type |
| `13`/`14` | Selection sort (max-selection + swap combined) | `mut` declaration inside a nested block |
| `15`/`16` | Partitioning (into two output arrays) | missing `(` before a dereference |
| `17`/`18` | Linear search in a struct array (by field) | `->` instead of `.` (no such operator exists) |
| `19`/`20` | Combination: counting + maximum in one function | stray comma in the simultaneous assignment |
| `21`/`22` | Combination: filtering + summation in one function | missing `}` in an array literal |
| `23`/`24` | A large program with multiple structs/functions/pointers/recursion — see 16.2 | missing `;` in a deeply nested function |

Every faulty case contains **exactly one** deviation from its correct
counterpart — the goal is an isolated demonstration of one concrete,
real-world programmer mistake, not an artificial input with stacked errors.

### 16.2 The large program (fixtures 23/24)

A small RPN (reverse Polish notation) expression evaluator: `Token` and
`Stack` structs, `stack_push`/`stack_pop` (modifying state through a pointer
parameter), `apply_op`, a **recursive** `gcd`, and an `eval_rpn` + `main`
that ties everything together — with two `extern function` declarations
(`sys_write`, `sys_exit`), nested struct and array literals, and the
`(*ptr).field[index]` pattern (the `*(T[N])` pointer-array design decision —
see chapter 5 of the main spec — is precisely what makes this form both
necessary and possible). Its purpose: to demonstrate, on an input
approaching the complexity of the compiler actually to be written, that the
parser (and in particular the `compute_line_col` line/column computation,
see chapter 11) works correctly even with many, mutually dependent
declarations — fixture 24 (the faulty one) specifically demonstrates that
even an error hidden deep (in the 4th declaration, in the middle of the
file) is reported at the exact correct line/column.

### 16.3 An observed gap — fixed at user request

While running the `04_count_error` fixture (`=` instead of `:=`), it came to
light that: a token carrying a **lexical** error (`TOK_ERROR`), when it ends
up in the "found <token-description>" portion of a syntax error, got an
**empty description** — the `.unknown:` branch of `err_append_token_desc`
(`parser_tokens.asm`) emitted nothing for `TOK_ERROR`/`TOK_ERROR_COMMENT`,
because these kinds fall into none of the known ranges (EOF/IDENT/INT/
keyword/operator/punctuation). The actual message therefore came out as
`"...found "`, without a token description — not a bug (it did not crash, it
did not mislead about position), just **less informative** than it could
be. Fixed after the fact, at user request:

- **`err_append_token_desc`** (`parser_tokens.asm`) got a new branch: for
  `TOK_ERROR`, the `TOK_LENGTH_OFF` field decides — if `1` (the lexer's two
  "bad character" producers, see chapter 7 of the lexer spec), it shows the
  actual character in quotes (`invalid character '='`); if `0` (the
  empty-based-digit-sequence producer), it gives a generic `invalid token`
  description, because there is no single concrete offending character to
  show there (and the byte at that position — if there is one at all — is
  not itself invalid). For `TOK_ERROR_COMMENT`, `unterminated comment`.
- **The same gap existed in the *lexer*'s own `report_error`** (`main.asm`)
  — it always unconditionally read and displayed the byte at
  `[tok+TOK_OFFSET_OFF]` as "unexpected character", **regardless of whether
  `TOK_LENGTH_OFF` was 0 or 1** — for the empty-based-digit-sequence case,
  this named an innocent byte unrelated to the error (or, at end of file, a
  zero byte coming from `.bss`) as the culprit. Fixed: `report_error` now
  branches on `TOK_LENGTH_OFF`, and for the length-0 case gives a dedicated
  `"based-form integer literal has no digits after 'n'"` message, instead
  of the "unexpected character" form — see chapter 7 of the lexer spec and
  `tests/cases/07_based_form_empty_digits`.
- Three new fixtures, each dedicated to exercising this error class
  (`38_expr_lex_error_bad_char`, `39_expr_lex_error_based_form_empty`,
  `40_expr_lex_error_unterminated_comment`), were added to the white-box
  suite (`tests/parser_cases/`) — these specifically test diagnostic
  quality rather than a particular grammar rule, but run through the `EXPR`
  directive like any other expression fixture. The `04_count_error`
  black-box fixture's `.expected.stderr` was re-recorded with the new,
  more informative message.

### 16.4 Why a separate directory and runner script

`tests/blackbox_cases/` + `scripts/run_blackbox_tests.sh` — the same
3-file `.expected.*` convention, the same `diff`-based runner logic as
`run_parser_tests.sh`, but in a **separate directory with a separate
script**, rather than extending the existing `parser_cases/` — the purpose
and reading mode of the two suites differ (isolated coverage of a single
grammar rule vs. the behavior of a complete program), and it also appears
as a separate `RUN` step in the `Dockerfile`, so that a future black-box
test failure is visible on its own in the build log, distinguishable from
the white-box suite.
