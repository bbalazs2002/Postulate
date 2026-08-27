# Postulate Stage 1 bootstrap plan — from proof of concept to Edsger

## About this document

This is the implementation roadmap for turning the Stage 1 proof of
concept (lexer + parser + scalar-only codegen, `Stage1/src/*.ptl`,
compiled by Hoare) into a real, modular, self-hosted, optimizing
compiler for the [v1 language](postulate_v1_language_reference.md). It
answers a question the language reference itself deliberately doesn't:
not *what* v1 is, but in what *order* to build it, and why that order.

**Versioning — `v{language}.{generation}.{step}`:**

- The **first** number names the **target language** — `1` for the
  language specified in `postulate_v1_language_reference.md`. This is
  a *direction*, not a completeness claim: Edsger `v1.0.n`/`v1.1.n`
  targets v1 without yet implementing all of it (floating point, for
  instance, is part of the v1 reference but doesn't land until
  `v1.1.4`, well after this scheme starts calling the compiler
  "`v1`-something") — the digit says which language the compiler is
  progressing toward, not how much of it already works. A genuinely new
  *language* generation (whatever eventually accumulates toward
  reference §11's remaining deferred items, with its own reference
  document) would be `v2`, not a bump to the second number — see
  "Beyond this plan."
- The **second** number is the compiler's own **generation** — `0` for
  everything up through and including the architectural rewrite
  (`v1.0.6`, §3): the original proof of concept, plus every step that
  still modified it rather than a real, modular compiler. `1` begins
  the moment the rewrite is done — the real, modular **Edsger** and
  everything built on top of it, unconditionally, however many further
  internal rewrites Edsger itself might someday need (a hypothetical
  later one would be `2`, and so on). This is the number that changed
  today: an earlier draft of this document used the second position for
  "language generation" instead, which put a future `v1.1` (a new
  *language*) and "Edsger's own next batch of work" (still targeting
  the same v1 language) in direct naming conflict. Splitting language
  (first number) from compiler generation (second number) removes that
  conflict entirely.
- The **third** number is the step count *within* that generation,
  restarting at `1` each time the middle number increments — `v1.0.1`
  through `v1.0.6` (generation 0), then `v1.1.1` onward (generation 1),
  not a single ever-growing counter across both.
- `v1.0.1` and `v1.0.4` are **retired** (§4) — never renumbered, kept
  as marked historical gaps rather than reused slots, since both are
  already cited by name in existing commits, fixtures, and design docs.

**Naming.** The lexer/parser/codegen trio built early in this project is
a **proof of concept only** and stays unnamed — it exists to prove
Hoare can bootstrap *something*, not to be anyone's long-term Stage 1
compiler. `v1.0.6` (§3) is the exact point where it gets rewritten into
a real, modular compiler; from that point on — generation `1`, in the
scheme above — the compiler is named **Edsger** (Stage 0's `Hoare`
honors C.A.R. Hoare; Stage 1's `Edsger` honors Edsger W. Dijkstra — the
same relational/predicate-transformer tradition §7 of the v1 reference
draws its verification vocabulary from). Every version from the rewrite
onward is "Edsger `v1.1.n`."

**Verification discipline.** Every step ships only once actually
**run** against real fixtures with checked exit codes/output, not just
"it parses" or "it compiles" — unchanged from how `v1.0.2`/`v1.0.3`
were verified. Starting at `v1.0.6`, this is refined into a
**module-by-module** discipline, not just an end-to-end one — see §3.

---

## Revision note: why this plan looks different now

This plan originally had `#include` (`v1.0.1`) as its cheapest,
independent first step, with true separate compilation and real
optimization bundled together as `v1.0.4`/`v1.0.5` immediately before a
`v1.0.6` rewrite that was scoped to introduce **no new language work at
all**. All three of those decisions were reconsidered, in order, after
a language-design pass replaced `#include` with a real namespace/`use`/
`@autoload` module system (`postulate_v1_language_reference.md` §6.2)
and added an optional Why3-based static verification path (§7.8) — and
then again after a decision to change *how* Stage 1 gets built, not
just what it builds next:

- **`#include` (`v1.0.1`) is retired.** Its entire mechanism — textual
  splicing, per-file include lists, the propagation rules that grew up
  around trying to keep that model both explicit and scalable — no
  longer exists in the language it was implementing. What replaces it
  (namespace/`use`/`@autoload`) is not a small patch to the existing
  lexer/parser; it needs new grammar, new resolution logic, and a
  different file-discovery model, so it is folded into `v1.0.6` rather
  than patched into the retired proof of concept.
- **True separate compilation (`v1.0.4`) is retired outright**, not
  reworked. The whole reason it existed — making `#include` scale past
  one-big-splice-per-build — is now the namespace system's own job by
  design (§6.2c): resolving a `use` never requires reading another
  module's body, only its interface, which is what `v1.0.4` was trying
  to engineer around `#include`'s textual-splice limitation in the
  first place. What's left of it — **incrementally** skipping
  recompilation of unchanged modules — is real, separable work, moved
  to its own later step (`v1.1.1`, below) rather than attempted
  alongside everything else `v1.0.6` already has to get right.
- **Real optimization (old `v1.0.5`) moves to after the rewrite.**
  Nothing about `opt` integration depends on anything `v1.0.6` adds —
  it was only ever grouped with the rewrite because both rode on the
  same LLVM IR switch (§2 still explains that shared mechanism) — but
  it competes for attention with the rewrite for no real benefit, and
  is genuinely lower-priority than making the intermediate compiler
  pleasant to write Edsger's own later stages in. It becomes `v1.1.2`.
- **Everything after the rewrite is numbered `v1.1.n`, not a continued
  `v1.0.n`.** The versioning scheme itself changed alongside all of the
  above: the second number now names the *compiler's own generation*
  (`0` through the rewrite, `1` for the real, modular Edsger and
  everything built on it) rather than "language generation" — freeing
  a future genuine new *language* generation to be `v2` without
  colliding with Edsger's own next batch of work, which still targets
  v1. See "Versioning," above, for the full reasoning.
- **`v1.0.6` itself grew, deliberately.** It no longer aims for "same
  language surface, new shape, no new syntax." It now front-loads
  three feature areas that were previously spread across `v1.0.6`,
  `v1.0.8`, and `v1.0.10` — namespaces/`use`/`@autoload`, `char` +
  `as`, and pointer arithmetic/`*void`/`uintptr`/`sizeof`/`lengthof` —
  into the rewrite itself, so that the *intermediate* compiler this
  step produces is already comfortable to keep developing Edsger's own
  later stages in, rather than staying scalar-and-`#include`-only for
  several more steps after the rewrite. Statement sugar, floats, and
  `main(argv, argc)` were all considered for the same treatment and
  deliberately left out — see §3's own note on why the line was drawn
  where it was.
- **The build/verification methodology itself changed.** Every step
  before this revision shipped as one, small, end-to-end-verified
  increment (lex → parse → check → codegen → run, for one feature, then
  the next). `v1.0.6`'s much larger scope makes that impractical to do
  feature-by-feature without constant rework across all four phases for
  every single addition; instead, `v1.0.6` is built and verified
  **module by module** — lexer, then parser, then semantic
  analyzer/type checker, then codegen — each covering the *entire*
  feature batch before the next module starts, each checked by hand
  against its own intermediate output before moving on. §3 spells this
  out in full.

---

## 1. Why the rewrite is front-loaded now

The original ordering put the cheapest, most self-contained thing
first (`#include`, having zero interaction with the type system or
codegen) and pushed the rewrite itself out to the point where
everything it needed to reorganize already existed. That reasoning
doesn't transfer cleanly to the current plan, because what `v1.0.6` now
has to reorganize *and* extend is no longer separable the same way:
namespaces/`use`/`@autoload` **is** the file-discovery and
module-boundary mechanism the new, modular Edsger architecture (§3) is
built around from day one — there's no version of "build the new
module structure first, add the module system that defines what a
module even is second" that makes sense. Front-loading `char`/`as`/
pointer arithmetic alongside it is a separate, practical call: writing
a real, multi-thousand-line compiler's later stages (semantic
analysis, contract checking, eventually Why3 translation) is
significantly more pleasant with byte-level text handling and
pointer-based data structures already available, and paying that cost
once, inside the rewrite, is cheaper than paying it in three more
separate steps immediately after.

## 2. Why LLVM IR came before the rewrite

*(Historical — `v1.0.2`/`v1.0.3` already shipped under this reasoning;
kept for context, not as forward-looking guidance.)*

Two things landed before the rewrite, sharing one underlying mechanism:
**Stage 1's codegen stopped emitting x86 NASM text directly and started
emitting LLVM IR instead.** This was not a new direction — it's the
path already named as the project's intended one (`Stage 0 asm → Stage
1 LLVM IR`) — just sequenced explicitly. Two consequences followed:

1. **Composite values across calls stopped needing a hand-rolled ABI**
   (`v1.0.3`) — LLVM IR has aggregate (struct/array) types as a
   first-class concept, and `llc` already knows how to lower them
   per-target, exactly the class of problem worth not re-solving by
   hand.
2. **Optimization and true separate compilation both stopped being
   from-scratch design problems** — `opt` (now `v1.1.2`) and per-module
   compilation (now folded into `v1.0.6`/`v1.1.1`) both ride on LLVM IR
   existing at all; neither needed designing before this switch, and
   neither would have been cheaper to build against a NASM-text
   backend first and then redo for LLVM immediately after.

**Adopting LLVM IR did not require reasoning about SSA form.** The
straightforward, standard technique (what `clang` itself does at `-O0`)
is one stack slot (`alloca`) per local, a load before every read, a
store after every write — letting `opt`'s `mem2reg` pass promote those
to registers automatically once optimization is actually turned on
(`v1.1.2`). This changes only which fixed-template text codegen
produces, not the shape of the logic deciding what to emit. This also
only ever changed Stage 1's own output — Hoare (Stage 0) stays exactly
what it is, a hand-written x86-64 NASM compiler, unaffected by anything
in this plan.

## 3. The rewrite point: where Edsger begins

**`v1.0.6` is the rewrite**, and now the largest single step in this
plan. By this point `#include` (retired) and the LLVM IR backend
(`v1.0.2`)/composite-call support (`v1.0.3`) already exist — the latter
two, unlike `#include`, don't need reworking, only reusing.

### What `v1.0.6` adds

- **Namespaces, `use`, and `@autoload`** (`postulate_v1_language_
  reference.md` §6.2/§6.2a/§6.2b) — full replacement for the retired
  `#include`. Dependency resolution only (§6.2c's caching is explicitly
  **not** attempted here — every build recompiles everything, always;
  that's `v1.1.1`). Path resolution for the default 1:1 mapping and
  `@autoload` patterns is relative to the compiler process's **current
  working directory** (`sys_openat(AT_FDCWD, ...)`, exactly the
  mechanism `#include` already used) — no command-line argument support
  is added for this; the entry (`\Main`) file's own text still arrives
  on stdin exactly as today, and everything it `use`s is resolved from
  there. Whether Edsger ever needs real `argv`/`argc` input of its own
  is left for whenever `main(argv, argc)` (`v1.1.5`) actually gets
  built into what Edsger itself can express — not decided now.
- **`char`, its literals and escapes, and `as` explicit conversion**
  (reference §1.5/§2.3/§3.7a) — pulled forward from the old `v1.0.8`.
- **Pointer arithmetic, `*void`, `uintptr`, cross-type pointer
  comparison, `sizeof`/`lengthof`** (reference §2.5–§2.7a) — pulled
  forward from the old `v1.0.10`.
- **Chained `T[N][M]...` nested-array declarations** (reference §2.7) —
  not part of either retired step; found and added during this step's
  own implementation, once Module 3's multi-file buffer table needed a
  real 2D array and v0/Hoare turned out never to have supported chained
  array-size suffixes at all (confirmed against `Hoare/src/type_
  parser.asm`; the v0 reference's own claim to the contrary was wrong
  and has been corrected).
- **The architecture rewrite itself**: the lexer/parser/codegen trio
  becomes real, separately-compiled modules — a lexer module, an AST
  module, a parser module, a **semantic analyzer / type checker
  module** (new — the proof of concept folded checking into codegen;
  Edsger does not), a codegen module, and thin per-phase driver
  files — and the index-arena AST workaround is replaced by a real,
  pointer-linked struct tree (`ASTNode` with `first_child`/
  `next_sibling` generic child-linking plus dedicated `left`/`right`/
  `extra` slots for common fixed-arity shapes, `Token` embedded by
  value, per the `Edsger-spec.md` sketch this design was worked out
  from). The workaround wasn't a permanent property of the language
  Edsger's own source is written in — v0 already supports
  self-referential struct pointers natively (`postulate_v0_language_
  reference.md` §2.6's own `struct Node { next : *Node; }` example);
  what actually blocked it before was reaching for heap allocation
  (`sys_mmap` returns `*uint8`, and v0 has no cast to reinterpret it,
  §2.8) as the way to get individually-allocated node pointers. A large,
  fixed-capacity local array of `ASTNode` plus `&pool[i]` (address-of an
  array element, already an ordinary v0 lvalue operation) produces real,
  individually-addressable `*ASTNode` values with no cast and no heap
  involved at all — the same bump-allocator-over-a-big-array shape the
  proof of concept's parallel arrays already used, just now yielding
  actual pointers instead of indices. **Two concrete adjustments** from
  the `Edsger-spec.md` sketch, since it was drafted against v1 syntax,
  not v0, and Edsger's own source can only use what v0 (plus this
  step's own additions) actually provides: `Token.lexeme` is `*uint8`,
  not `*char` (`char` is new *to the language Edsger compiles*, but
  isn't needed for Edsger's *own* source to represent raw source
  bytes — the proof of concept never used it either); and no field
  needs a float type yet (`ASTExpr`/`Symbol`-style float-literal storage
  waits for `v1.1.4`, since Edsger's own source has no float type to
  store one in before then).

### What `v1.0.6` deliberately still leaves out

**Statement sugar** (`elseif`/`break`/`continue`/compound assignment/
`++`/`--`), **floating point**, and **`main(argv, argc)`** were each
considered for pulling forward alongside the three feature areas above,
for the same "make the intermediate compiler comfortable to write in"
reason — and each was deliberately left where it already was:
statement sugar is real, separable work with no dependency relationship
to anything else in this step, floats have no use inside a compiler
that never computes with them, and `@autoload`'s own file resolution
(above) already removes the practical need for real command-line
arguments this step might otherwise have created. Pulling all three
forward "since we're already doing a big batch" would have made an
already-large step larger for no load-bearing reason.

### Module-by-module construction and verification

This is the methodology change: instead of one small, fully
end-to-end-verified increment per feature, `v1.0.6`'s entire feature
batch is built **one whole module at a time**, each covering every
feature this step adds before the next module starts:

1. **Lexer.** Extended for every new token this step needs (`namespace`,
   `use`, `@autoload`, `verified`/`unverified`, `\`, `@`, `char`
   literals and escape sequences, `as`, the pointer-arithmetic-related
   operators already in the grammar). Verified by dumping the token
   stream for a battery of test files that between them exercise every
   new token shape, checked **by hand** before moving on — not run,
   since a token stream isn't a program.
2. **Parser.** Extended grammar for `namespace_decl`/`use_decl`/
   `autoload_decl`, `char` literals, `as`-casts, and pointer-arithmetic
   expressions, built directly against the new pointer-linked `ASTNode`
   representation rather than the old arena. Verified by dumping the
   resulting tree (walking `first_child`/`next_sibling` and the
   dedicated slots) for the same test files, checked by hand.
3. **Semantic analyzer / type checker.** The new, previously-nonexistent
   module: builds the symbol table, resolves every `use`/`@autoload`
   reference to a concrete file and, transitively, a concrete
   declaration, and decorates the AST (inferred types, symbol
   references, constant-ness) — including the type rules `char`/`as`/
   pointer arithmetic add. Verified by dumping the decorated tree/symbol
   table, checked by hand.
4. **Codegen.** Emits LLVM IR from the decorated tree, reusing and
   extending `v1.0.2`/`v1.0.3`'s existing emission logic. This is the
   one module still verified the original way: assembled with `llc`,
   linked with `ld`, and actually **run**, against real fixtures with
   checked exit codes — the end-to-end discipline every step before
   this one already used, now applied once, at the end of the whole
   batch, rather than once per feature.

Each of the first three checkpoints is a genuine gate — the user
reviews that module's own output by hand before the next module is
started — not a formality. This trades "every single feature is
independently, fully proven correct before the next begins" (the old
discipline) for "every module is independently, fully built and
manually checked for the whole batch before the next module begins" —
a different, not weaker, decomposition of the same verification goal,
chosen because it matches how the new architecture (§3's own module
split) actually separates concerns, and because rebuilding all four
modules from scratch for each of ~six features one at a time would
mean touching the same four files six times over for no benefit once
they're being written fresh anyway.

Full regression, at the end: every fixture the proof of concept already
passed (Hoare's `cases`/`codegen_cases`/`checker_cases`/`blackbox_cases`,
plus `v1.0.2`/`v1.0.3`'s own suites), expecting identical, correct
results — the rewrite is not allowed to also be where old behavior
quietly breaks.

From `v1.0.6` onward, the compiler is called **Edsger**. Everything
before it (`v1.0.1`–`v1.0.5`, retired or not, and the original,
unversioned proof of concept) stays nameless — scaffolding that did
its job.

## 4. Full step list

| Version | Adds | Why here |
|---|---|---|
| `v1.0.1` | **Retired.** Was `#include` (relative-path resolution, recursive splice, include-once, cycle detection). Superseded in full by namespaces/`use`/`@autoload` (§6.2), built as part of `v1.0.6`. Historical design doc: [`postulate_stage1_v1_0_1_include_design.md`](postulate_stage1_v1_0_1_include_design.md) (describes a mechanism no longer part of the language). | See "Revision note" above. |
| `v1.0.2` | **Done.** Codegen backend switch: emit LLVM IR instead of x86 NASM text; `llc` replaces `nasm`. Same scalar-only feature set as before — a backend swap, not a feature addition. | Foundation for composites, optimization, and per-module compilation alike — §2. |
| `v1.0.3` | **Done.** Composite (struct/array) parameters and return values in Stage 1's own codegen — v0 parity. Structs, arrays, broadcast-init, pointers (scalar and composite pointees, including self-referential struct fields), and the by-value calling convention. Design: [`postulate_stage1_v1_0_3_composites_design.md`](postulate_stage1_v1_0_3_composites_design.md). | Implemented directly against LLVM IR's native aggregate types — §2. |
| `v1.0.4` | **Retired.** Was true separate compilation, designed against `#include`'s textual-splice model. Never implemented. What it was trying to achieve is now the namespace system's own design property (§6.2c), not a separate mechanism to build. Superseded design doc: [`postulate_stage1_v1_0_4_separate_compilation_design.md`](postulate_stage1_v1_0_4_separate_compilation_design.md) (describes a mechanism the current language design doesn't need). | See "Revision note" above. |
| **`v1.0.5`** *(placeholder — see `v1.1.2`)* | *(retired slot — optimization moved to `v1.1.2`; kept blank rather than reused, so no future step is ever ambiguously "the same number as something else.")* | — |
| **`v1.0.6`** | **The Edsger rewrite. Generation `0` ends here.** Namespaces/`use`/`@autoload` (dependency resolution only, no caching); `char` + `as`; pointer arithmetic/`*void`/`uintptr`/`sizeof`/`lengthof`; full modular architecture (lexer/AST/parser/semantic-analyzer-and-type-checker/codegen as real, separate modules; pointer-linked `ASTNode` tree replacing the index arena). Built and verified **module by module**, each module covering the whole feature batch, each checked by hand before the next starts (§3). Design: [`postulate_stage1_v1_0_6_edsger_design.md`](postulate_stage1_v1_0_6_edsger_design.md). | §1/§3 — the module system is the architecture's own foundation, not an add-on to it; `char`/`as`/pointer arithmetic front-loaded so Edsger's own later stages are comfortable to write. |
| **`v1.1.1`** *(generation `1` begins — Edsger proper)* | Incremental compilation: skip recompiling a module whose own source is unchanged **and** whose `use`d dependencies' own *interfaces* — not merely their compiled bodies — are unchanged since its last successful compile (§6.2c's caching half, deliberately deferred out of `v1.0.6`). Cache-key scope is deliberately narrow: a module's own source hash, plus, per direct `use`d dependency, that dependency's *interface* hash as of this module's last compile — never a dependency's full body hash, and never anything from further down the transitive chain. This is what keeps a body-only edit in one module from cascading into recompiling everything that (even indirectly) depends on it. | Genuinely separable from `v1.0.6`'s dependency-*resolution* work; not worth the risk of getting both right at once. |
| `v1.1.2` | Optimization turned on: each module's LLVM IR routed through `opt` at a chosen level before `llc`. | Moved here from the old `v1.0.5` — rides on the same LLVM IR switch (§2), but no longer competes with the rewrite for priority; verified by re-running the full fixture suite under optimization. |
| `v1.1.3` | Statement sugar: `elseif` (§4.3), `break`/`continue` (§4.6), compound assignment `:+ :- :* :/` (§4.2), `++`/`--` (§4.2a). | Pure desugaring, no new types — deliberately left out of `v1.0.6` (its own note) since it has no dependency relationship to that batch. |
| `v1.1.4` | Floating point: `float32/64`, `ufloat32/64`, literals, `+ - * /`, comparisons incl. NaN, `**` (exponent), `_/` (root, desugars to `**`) (§2.4, §3.2). | Self-contained type family; reuses `as` from `v1.0.6`. |
| `v1.1.5` | `main(argv, argc)` two-parameter form; atomic-only `main` return type, compiler-enforced (§6.3). | Needs `**char`/pointer-array understanding from `v1.0.6`'s pointer arithmetic; deliberately not pulled into `v1.0.6` itself (its own note) since `@autoload` already covers Edsger's own near-term file-resolution needs. |
| `v1.1.6` | `ref` parameters (§5.3a). | Independent of the above; a calling-convention addition, not a type addition. |
| `v1.1.7` | Operator overloading (§5.4). | Needs nothing new beyond ordinary function-checking machinery; deliberately last of the "small features," least load-bearing for anything else in this list. |
| `v1.1.8` | Verification contracts, part 1: grammar, all seven contextual keywords (`requires`/`ensures`/`invariant`/`decreases`/`old`/`result`/`last`), full semantic validation (§7.1–§7.2, §7.6–§7.6b, §8.1). Zero runtime cost — a normally-compiled program emits no contract code at all. | The bulk of the contract system's complexity (contextual-keyword parsing, purity checking, the no-self-reference rule) isolated from codegen risk; everything from `v1.1.3`–`v1.1.7` needs to exist first since contract expressions can mention any of it. |
| `v1.1.9` | Verification contracts, part 2: the opt-in checked-build codegen mode (§7.3–§7.5) — runtime assertions at every specified checkpoint, halt-with-diagnostic on failure. | Split from `v1.1.8` deliberately: parsing/checking a contract correctly and *emitting code* for one are separably testable, and this is the riskier of the two. |
| `v1.1.10` | Static verification: the Why3/WhyML translation path and `postulate verify` tool (§7.8) — modular, axiom-per-`use`d-contract, `verified`-prefix-aware, incremental per `v1.1.1`'s own cache. Also where the cache's own remaining open questions (`.proof` validity relative to `unverified`-trusted axioms; a compiler-generation/build-identity component in the cache key, so an Edsger upgrade can't silently serve stale `.pto`/`.proof` entries) get resolved. | Needs `v1.1.8`'s contract grammar/semantics and `v1.1.1`'s incremental-compilation machinery (reused, not reinvented, for verification caching); entirely optional and separate from the default build (§7.5/§7.8), so it can land after everything the default pipeline needs. |
| `v1.1.11` | Bounds-checking diagnostic build (§2.7b) — array indexing checked against `lengthof` in an opt-in build. | Same opt-in-diagnostic-build mechanism `v1.1.9` already built; reuses it rather than inventing a second one. |
| `v1.1.12` | Self-hosting closure: Edsger compiles itself (Hoare → Edsger₁ from source; Edsger₁ → Edsger₂ from the same source; Edsger₂'s output agrees with Edsger₁'s). | The actual bootstrap goal (`Stage1/README.md`'s opening line) — only meaningful once the full v1.0 surface exists, since Edsger's own source will by then use most of it. |

### Tracked checkpoint: struct-field layout, before `v1.0.6`

`v1.0.3`'s composite sub-pass represents struct fields packed, with
zero padding between them — matching v0's own language-level layout
guarantee exactly (`postulate_v0_language_reference.md` §2.6) via
LLVM's native packed struct type. Whether that guarantee itself should
ever change (e.g. toward natural/ABI alignment, for raw-memory-access
performance or a future FFI's sake) is **explicitly not decided now** —
deliberately deferred, not silently carried forward as permanent. This
is a placeholder to make sure it gets a real look before `v1.0.6`
closes out the still-single-file proof-of-concept era, rather than
being forgotten between now and then.

## 5. What's deliberately not in this plan

Everything the reference's §11 lists as **deferred beyond v1** stays
deferred here too: static verification's whole-project completeness
guarantee beyond the per-module, opt-out-able coverage `v1.1.10`
provides; a `string`/console-I/O/threading standard library; struct
field reflection; a general FFI; polymorphism/generics; and any
language-level data-race protection. None of them are scheduled as a
step in this plan. Namespaces are **not** on this list anymore — they
are core v1 (§6.2), built as part of `v1.0.6` above, not a future
language generation.

## Beyond this plan

Once `v1.1.12` closes the self-hosting loop, Hoare (Stage 0) becomes
historical — every future change targets Edsger's own source, compiled
by itself, and further Edsger work continues as `v1.2.n`, `v1.3.n`, and
so on — new compiler generations, still targeting v1, numbered exactly
as this plan's own "Versioning" section describes. Whatever eventually
accumulates toward a genuinely new *language* generation (reference
§11's remaining deferred items) becomes `v2`, with its own reference
document and its own version of this plan (`v2.0.n`) once that design
work happens — not a continuation of the numbers above, and not `v1.1`
(already spoken for by Edsger's own first post-rewrite generation,
above).
