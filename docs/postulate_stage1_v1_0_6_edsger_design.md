# `v1.0.6` design: the Edsger rewrite

## Scope

This is the implementation design for `v1.0.6` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md) — the
point where the proof-of-concept lexer/parser/codegen trio is retired
and the compiler becomes **Edsger**: a real, modular compiler with a
pointer-linked AST, extended in the same pass to cover namespaces/`use`/
`@autoload`, `char`/`as`, and pointer arithmetic. It builds directly on
`temp/Edsger-spec.md`'s own architecture sketch (lexer → parser →
semantic analyzer/type checker → codegen, feeding either LLVM IR or a
future Why3 translation), adjusted in the specific places that sketch
assumed capabilities the language Edsger's *own source* doesn't have
yet — see "Two adjustments" below. What this document does **not**
re-litigate: the language semantics themselves (namespaces, `char`,
pointer arithmetic) are already fully specified in
`postulate_v1_language_reference.md` §6.2/§1.5/§2.3/§2.5–§2.7a/§3.7a;
this document is about how Edsger implements them, and how it's built
and checked.

## Source layout: real modules, not one file per phase

The proof of concept was three self-contained files, each duplicating
whatever it needed from earlier phases, because v0 had no `#include`
and nothing to duplicate it *into*. That constraint is gone —
namespaces/`use`/`@autoload` (below) are themselves the mechanism that
makes real modularity possible — so Edsger is laid out as genuinely
separate compilation units:

- **`lexer.ptl`** — character stream → token stream.
- **`ast.ptl`** — the `ASTNode`/`Token` struct definitions and the node
  arena (below); a leaf module everything else depends on, depending on
  nothing itself.
- **`parser.ptl`** — token stream → `ASTNode` tree, using `ast.ptl`.
- **`sema.ptl`** — the semantic analyzer / type checker: symbol table,
  `use`/`@autoload` resolution, type inference and checking, AST
  decoration.
- **`codegen.ptl`** — decorated tree → LLVM IR.
- Thin per-phase driver files, exactly as the proof of concept already
  had, one per standalone binary (`lexer`, `parser`, `sema`, `codegen`)
  for independent testing, per the module-by-module discipline below.

## The AST: a real pointer-linked tree

### The arena: a big local array, not a heap

v0 has no cast (`postulate_v0_language_reference.md` §2.8) and
`sys_mmap` only ever returns `*uint8` — there is no way to turn mmap'd
memory into a `*ASTNode` in real v0. That looked, at first, like it
ruled out a genuine pointer-linked tree for Edsger's own source, the
same way it already forced the proof of concept's index-based arena.
It doesn't: v0 already supports **self-referential struct pointers**
natively (§2.6's own showcase, `struct Node { value : int32; next :
*Node; }`) and **address-of an array element** as an ordinary lvalue
operation (§2.4/§3.10, `&arr[i]`). A single, large, fixed-capacity
local array —

```postulate
mut node_pool : ASTNode[MAX_NODES];
mut node_count : uint64 := 0;
```

— combined with a bump allocator (`&node_pool[node_count]`, then
`node_count := node_count + 1`) produces a real, individually-
addressable `*ASTNode` for every node, with **no cast, no heap, and no
new language feature** — `&node_pool[i]`'s type is already `*ASTNode`
directly, because `node_pool`'s element type is `ASTNode`. This is
mechanically the same bump-allocator-over-one-big-array shape the
proof of concept's parallel `uint64` arrays already used; the only
thing that changes is that the arena now holds real `ASTNode` values
and hands out real pointers into itself, instead of holding parallel
scalar fields and handing out `uint64` indices.

### Struct definitions

Adapted directly from `temp/Edsger-spec.md`, with the two adjustments
below:

```postulate
struct Token {
    type   : uint32;   // TOKEN_KEYWORD_IF, TOKEN_IDENTIFIER, TOKEN_PLUS, ...
    lexeme : *uint8;   // pointer into the source buffer, not a copy
    length : uint32;
    line   : uint32;
    column : uint32;
}

struct ASTNode {
    kind         : uint32;      // NODE_* constant
    token        : Token;       // primary token, for diagnostics and position

    first_child  : *ASTNode;    // generic child/sibling linking, for
    next_sibling : *ASTNode;    // variable-arity lists (block statements,
                                 // parameter lists, use-group members, ...)

    data_type    : *ASTNode;    // for an expression/declaration: the AST
                                 // node describing its type (reusing the
                                 // type-expression's own parse rather than
                                 // a separate Type struct — kept
                                 // deliberately uniform with Symbol's own
                                 // type_info field, below)
    is_mutable   : bool;        // 'mut' vs 'const', or a 'ref' parameter flag

    string_val   : *uint8;      // identifier name, namespace path segment,
                                 // or (once string literals exist) literal text
    int_val      : int64;       // integer literal value

    op_type      : uint32;      // binary/unary operator code

    left         : *ASTNode;    // dedicated slots for fixed-arity shapes --
    right        : *ASTNode;    // e.g. if: left = condition, right = then-branch,
    extra        : *ASTNode;    // extra = else-branch; binop: left/right = operands
}

struct SyntaxError {
    message : *uint8;
    line    : uint32;
    column  : uint32;
}
```

Symbol table, built during semantic analysis (its own arena, same
bump-allocator shape):

```postulate
struct Symbol {
    name       : *uint8;
    kind       : uint32;    // SYM_VAR, SYM_FUNC, SYM_STRUCT, SYM_EXTERN
    type_info  : *ASTNode;  // reuses the same "AST node as type descriptor"
                             // idea ASTNode.data_type already uses, rather
                             // than introducing a second, separate Type
                             // representation for the same concept
    is_mutable : bool;
    is_defined : bool;
    line       : uint32;
}

struct SemanticError {
    message : *uint8;
    line    : uint32;
    column  : uint32;
}
```

`ASTExpr`-style decoration (`inferred_type`, `symbol_ref`, `is_constant`
from the original sketch) is **not** a separate struct — it's fields
added directly to `ASTNode` itself (`data_type` doubling as
`inferred_type` once semantic analysis has run; a new `symbol_ref :
*Symbol` field; `is_constant : bool`), since v0 has no notion of
"the same tree, but with extra fields," only one struct shape per node
— decorating in place, the way the proof of concept's codegen already
decorated its own arena's parallel arrays in place, carries over
directly.

### Two adjustments from `Edsger-spec.md`'s own sketch

`Edsger-spec.md` was drafted directly against v1 syntax, not against
what v0 (plus this step's own additions) actually provides for writing
Edsger's *own* source:

1. **`*char`, everywhere, becomes `*uint8`.** `char` is new *to the
   language Edsger compiles* (this step adds it, per the language
   reference) — it isn't needed for Edsger's *own* source to represent
   raw source bytes, and the proof of concept never used it either
   (`Stage1/README.md`'s own "no string literals" note explains why
   byte arrays are the standing convention throughout this codebase).
2. **No field stores a float.** `float_val : float64` has nothing to
   be stored in — Edsger's own source has no float type until
   `v1.1.4`. A float literal encountered before then is out of scope
   for this step's own lexer/parser (floats aren't part of `v1.0.6`'s
   feature batch at all) — this only matters as a note for whoever
   eventually extends this same struct at `v1.1.4`, not a decision
   this step has to make now.

### Sizing and the stack-size risk

v0 has no global/static variables (`postulate_v0_language_reference.md`
§6/§7 — every declaration is function-local) and no usable heap for
this purpose (above) — the `ASTNode` pool can only live on the stack,
inside `main()`'s own frame (or a struct pointer threaded from there,
exactly like the proof of concept's existing `Bufs`-style parameter
passing). Each `ASTNode` is, packed per §2.6's zero-padding guarantee:
`kind`(4) + `token`(24) + `first_child`/`next_sibling`/`data_type`(24)
+ `is_mutable`(1) + `string_val`(8) + `int_val`(8) + `op_type`(4) +
`left`/`right`/`extra`(24) = **97 bytes**. The proof of concept's own
`codegen.ptl` already declares three separate 1 MiB locals plus dozens
of smaller arrays in one stack frame and runs correctly under Hoare
today — a `node_pool : ASTNode[50000]` (≈4.85 MiB) sits comfortably
inside that already-proven envelope; a `[100000]` pool (≈9.7 MiB)
starts to approach the conventional 8 MiB Linux default stack limit
once combined with every other local in the same frame, and nothing in
`Hoare/src/codegen_main.asm`'s `_start` or the v0 reference sets up a
non-default stack size. **Start at `MAX_NODES = 50000`** (generous for
any Stage 1 fixture written so far, by a wide margin) and treat a
larger cap as something to revisit only if a real program's own AST
turns out to need it — checked empirically (does the binary actually
run without a stack-overflow crash) rather than assumed. The symbol
table's own pool is far cheaper (`Symbol` packs to 26 bytes; even
`Symbol[8192]` is ≈213 KiB) and isn't a sizing concern.

## Module 1: Lexer

Extended for every token this step's feature batch needs: `namespace`,
`use`, `@autoload`, `verified`, `unverified`, `\` (namespace/path
separator), `@` (autoload-directive marker), `char` literals and their
escape sequences (§1.5), `pure_string_literal` for `@autoload`'s own
`pattern_string`/`path_string` operands (§1.5/§6.2b — **no** escape
processing at all, deliberately: a filesystem path never needs one, and
requiring `\\` for every namespace-path separator a pattern/path string
is full of would only be friction with no payoff. The reference also
names a second, escape-carrying `string_literal`, reusing `char`'s own
`char_body`/`escape_seq` unit, for whenever a real general string type
exists — nothing accepts one yet, so this lexer has no reason to
recognize it either), `as` (already a keyword, now used in the
`use ... as ...` position too — no new token, just a new valid position
for an existing one, per the language reference's own note that the two
`as` contexts never collide), and nothing new for pointer arithmetic
itself (`+`/`-`/comparison operators already exist; what changes is
which *types* they're legal between, a semantic-analyzer concern, not a
lexer one).

**Verification**: dump the token stream (kind, lexeme, line, column)
for a battery of fixtures that between them cover every new token
shape — `namespace \A\B;`, every `use` form (§6.2a's three), every
`@autoload` form including the `:module` placeholder, `char` literals
including every escape (`\n \t \r \0 \\ \'`), and `as` in both its cast
and `use`-renaming positions. Checked by hand; not run, since a token
dump isn't a program.

## Module 2: Parser

Extended grammar: `namespace_decl`, `use_decl` (all three forms),
`autoload_decl`, `char_literal`, and pointer-arithmetic expressions
(ordinary binary `+`/`-` between pointer- and integer-typed operands —
new *type* rules, not new grammar productions, since `+`/`-` are
already binary operators). Built directly against the `ASTNode` arena
(above) rather than the retired index arena — every `alloc_node`-style
call becomes "claim the next pool slot, populate it, return
`&node_pool[claimed_index]`."

**Verification**: dump the resulting tree for the same fixture battery
— a simple recursive walk over `first_child`/`next_sibling`, printing
each node's `kind` and relevant fields, indented by depth, with
`left`/`right`/`extra` walked as well wherever a node kind uses them.
Checked by hand.

## Module 3: Semantic analyzer / type checker

New as a genuinely separate module — the proof of concept folded this
into codegen; Edsger does not, matching `Edsger-spec.md`'s own
architecture. Three responsibilities:

1. **Symbol table construction** — the `Symbol` arena (above), one
   entry per top-level declaration, per module.
2. **`use`/`@autoload` resolution** — for each `use_decl`, resolve its
   fully-qualified name(s) to a concrete file path (default 1:1
   mapping, or the first matching `@autoload` pattern, checked
   top-to-bottom, per §6.2b), open it (`sys_openat`, path resolved
   relative to the compiler process's **current working directory** —
   no command-line argument support is added for this in `v1.0.6`; the
   entry file's own text still arrives on stdin, exactly as the proof
   of concept already does it, and `@autoload`'s own resolution logic
   is what removes the practical need for argv-driven paths this step
   might otherwise have created), and recursively resolve *that* file's
   own top-level declarations far enough to populate the symbol table
   entries it exposes — never its function bodies, per §6.2c's own
   "signatures and contracts only" principle (nothing here caches that
   result across separate compiler invocations yet — that's `v1.1.1`;
   within one invocation, a file `use`d twice is still only opened and
   resolved once).
3. **Type checking and decoration** — walks the tree, resolving every
   identifier against the symbol table, checking `char`/`as`/pointer-
   arithmetic's own type rules (§2.3/§2.5/§3.7a), and writing
   `data_type`/`symbol_ref`/`is_constant` back onto each `ASTNode` in
   place.

**Verification**: dump the decorated tree (as in Module 2, plus each
node's resolved `data_type`/`symbol_ref`) and the symbol table itself,
for the same fixture battery plus new fixtures specifically exercising
multi-file `use`/`@autoload` resolution (a plain default-mapped
`use`, a pattern-matched `@autoload` override, a group import, a
namespace-level import) and the new type rules (a legal and an illegal
pointer-arithmetic expression, a legal and an illegal `as` conversion,
per §3.7a's table). Checked by hand.

## Module 4: Codegen

Emits LLVM IR from the decorated tree — reusing and extending
`v1.0.2`/`v1.0.3`'s existing emission logic (struct/array layout,
calling convention, pointer handling all carry over unchanged; new
work is limited to `char` (an 8-bit integer at the LLVM level, per
§1.5), `as` conversions (§3.7a's table, mostly `zext`/`sext`/`trunc`/
`ptrtoint`/`inttoptr`), and pointer arithmetic (`getelementptr`).
Namespaces/`use`/`@autoload` have no codegen footprint of their own —
by the time codegen runs, every reference has already been resolved to
a concrete symbol by Module 3; codegen never sees a fully-qualified
name at all.

**Verification**: the one module still verified the original,
end-to-end way — assembled with `llc`, linked with `ld`, and actually
**run**, against real fixtures with checked exit codes. Full
regression at this point too: every fixture the proof of concept and
`v1.0.2`/`v1.0.3` already pass, expecting identical results.

## Testing plan

1. **Per-module fixture battery** (built once, reused across all four
   modules' own checkpoints): namespace declarations, all three `use`
   forms, `@autoload` with and without `:module` patterns, `verified`/
   `unverified` flags, `char` literals and every escape, `as` in both
   its contexts, legal and illegal pointer arithmetic, legal and
   illegal `as` conversions.
2. **Multi-file resolution fixtures**: a small project (entry file +
   two or three `use`d files, at least one reached only through a
   default-mapped path and one through an `@autoload` override)
   compiles and runs correctly end-to-end.
3. **Arena capacity**: a deliberately large fixture (many declarations,
   deeply nested expressions) confirms `node_pool`'s chosen size
   doesn't overflow, and that Edsger's own process doesn't hit a stack
   limit compiling it.
4. **Full regression**: every fixture from the proof of concept and
   `v1.0.2`/`v1.0.3`, run through the new pipeline end-to-end, expecting
   byte-identical exit codes/output to before.
