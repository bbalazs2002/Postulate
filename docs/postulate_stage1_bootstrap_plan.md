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

**Directory name.** Edsger's own working directory in the repository is
`Edsger_v0/` (renamed from a plain `Edsger/` on 2026-08-28), *not* a
second compiler-generation counter of its own — that's still tracked by
the `v1.0.n`/`v1.1.n` scheme above, currently sitting at generation `0`
(the rewrite itself; see the "Resolved checkpoint"/"Tracked" sections
below for what's landed inside it since). The suffix names what's
already true of everything under it: this generation's entire source
tree is v0 syntax, compiled by Hoare — the same fact the module
docstrings already state ("Written in Postulate v0, compiled by Hoare
(Stage 0)"), now also visible at the path level. It is unrelated to
`Stage1/` (§0's "proof of concept," a separate, older, already-retired
codebase this plan's own opening paragraph describes — not a second
attempt at Edsger under a different name). See "A self-hosting dry
run," below, for what `_v0` will stop meaning once `v1.1.13` actually
closes the self-hosting loop.

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
| `v1.0.1` | **Retired.** Was `#include` (relative-path resolution, recursive splice, include-once, cycle detection). Superseded in full by namespaces/`use`/`@autoload` (§6.2), built as part of `v1.0.6`. Its own design doc (`postulate_stage1_v1_0_1_include_design.md`, describing a mechanism no longer part of the language) has since been deleted — the one piece of it with lasting value, adding `sys_openat`/`sys_close` to the `extern function` whitelist to unblock file I/O, is already folded into `postulate_v1_language_reference.md` §5.2's own table and `postulate_v0_language_reference.md`'s own extern-table note. | See "Revision note" above. |
| `v1.0.2` | **Done.** Codegen backend switch: emit LLVM IR instead of x86 NASM text; `llc` replaces `nasm`. Same scalar-only feature set as before — a backend swap, not a feature addition. Its own design doc (`postulate_stage1_v1_0_2_llvm_backend_design.md`) has since been deleted; the one piece of it not yet carried into Edsger — the extern/syscall inline-asm and `_start` emission technique — is preserved in the "Tracked checkpoint: extern/syscall calls and `_start`" section below, not lost. | Foundation for composites, optimization, and per-module compilation alike — §2. |
| `v1.0.3` | **Done.** Composite (struct/array) parameters and return values in Stage 1's own codegen — v0 parity. Structs, arrays, broadcast-init (scalar **or** struct source, both at decl-init and at plain assignment — reference §4.1/§4.2, `v1.1.12` below), pointers (scalar and composite pointees, including self-referential struct fields), and the by-value calling convention. Its own design doc (`postulate_stage1_v1_0_3_composites_design.md`) has since been deleted; its broadcast-init scope finding and its `_start`/`main`-return-width note are preserved in `v1.1.12` and the "Tracked checkpoint" section below, respectively. | Implemented directly against LLVM IR's native aggregate types — §2. |
| `v1.0.4` | **Retired.** Was true separate compilation, designed against `#include`'s textual-splice model. Never implemented. What it was trying to achieve is now the namespace system's own design property (§6.2c), not a separate mechanism to build. Its own design doc (`postulate_stage1_v1_0_4_separate_compilation_design.md`, describing a mechanism the current language design doesn't need) has since been deleted — nothing in it survived its own retirement, since none of it was ever built. | See "Revision note" above. |
| **`v1.0.5`** *(placeholder — see `v1.1.2`)* | *(retired slot — optimization moved to `v1.1.2`; kept blank rather than reused, so no future step is ever ambiguously "the same number as something else.")* | — |
| **`v1.0.6`** | **The Edsger rewrite. Generation `0` ends here.** Namespaces/`use`/`@autoload` (dependency resolution only, no caching); `char` + `as`; pointer arithmetic/`*void`/`uintptr`/`sizeof`/`lengthof`; full modular architecture (lexer/AST/parser/semantic-analyzer-and-type-checker/codegen as real, separate modules; pointer-linked `ASTNode` tree replacing the index arena). Built and verified **module by module**, each module covering the whole feature batch, each checked by hand before the next starts (§3). Its own design doc (`postulate_stage1_v1_0_6_edsger_design.md`) has since been deleted — it described *how* to build what this row and §3 above already fully describe, and Edsger's own shipped source (`Edsger_v0/src/*.ptl`) is now the more authoritative, more precise record of the actual result. | §1/§3 — the module system is the architecture's own foundation, not an add-on to it; `char`/`as`/pointer arithmetic front-loaded so Edsger's own later stages are comfortable to write. |
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
| `v1.1.12` | Array **broadcast-init and broadcast-assignment** (reference §4.1/§4.2): a single expression whose type exactly matches an array-typed `mut`/`const`/`lvalue`'s own element type — a scalar, **or a struct exactly matching an array-of-that-struct's element type** (`mut pts : Point[4] := p;`, not scalar-only) — as a `decl` initializer or a plain `:=` right-hand side, coerced/copied exactly once and that one value stored into every element (never re-evaluated per element). Already real, working v1 behavior once — Stage 1's own pre-rewrite proof of concept implements both the scalar and the struct-source shape, at both decl-init and assignment (`v1.0.3`'s own composite work, table row above; the struct-source shape was itself a mid-implementation discovery there, cross-checked directly against `Hoare/src/sema_stmt.asm`'s `check_array_broadcast_compatible` after an initial, too-narrow "scalar only" assumption) — but never carried into Edsger's Sema/Codegen: `v1.0.6`'s composite-type round (types, locals, parameters/return, field/index access, whole-value copy, struct/array literals) has no broadcast path of any kind, in either `check_expected`/`decorate_literal_with_expected` (Sema) or the codegen side. Found during that round and deliberately left unfixed there rather than touched after the round had already shipped and passed its own test suite. A source whose type doesn't exactly match the element type (scalar-vs-struct-element, or two different structs) must be a codegen/Sema error, not a silent miscompile — the old proof of concept's own testing caught a real bug of exactly this shape (see "Tracked checkpoint," below, for the general lesson about GEP index shapes that bug illustrates). | Small and fully self-contained — depends only on `v1.0.6`'s existing array-type support, nothing from `v1.1.1`–`v1.1.11`. Sequenced last among the ordinary feature steps (immediately before self-hosting closure) simply because it was found after this list was already drafted, not because anything here actually depends on the rest of generation `1`. |
| `v1.1.13` | Self-hosting closure: Edsger compiles itself (Hoare → Edsger₁ from source; Edsger₁ → Edsger₂ from the same source; Edsger₂'s output agrees with Edsger₁'s). | The actual bootstrap goal (`Stage1/README.md`'s opening line) — only meaningful once the full v1.0 surface exists, since Edsger's own source will by then use most of it. |

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

### Resolved checkpoint: extern/syscall calls and `_start`

**Done, 2026-08-28** — originally tracked here as an open gap (kept
below as the historical record of what was missing and why, and as the
technique reference the actual implementation followed). `v1.0.6`'s own
Module 4 (Codegen) description above says it emits LLVM IR "reusing and
extending `v1.0.2`/`v1.0.3`'s existing emission logic" — true for
scalar/composite/pointer codegen, but Edsger's `codegen.ptl` had never
implemented the one piece of `v1.0.2` that made a *compiled program*
itself runnable: an emitted entry point and an exit syscall. Every
Edsger program compiled to a `define ... @main(...)` and nothing else —
no `_start`, no way to call `extern function sys_write`/`sys_exit`/etc.
at all, and consequently no way to link a compiled program into a
binary that did anything observable or even exited cleanly. Fixed by
adding, to `codegen.ptl`: `gen_start` (emits a real `define void
@_start()` for whichever file declares `main`, per the technique below),
`gen_syscall_extern`/`gen_raw_syscall`/`syscall_number_for`/`is_syscall_
safe_type` (back each of the twelve whitelisted `extern function`s with
a real inline-asm syscall wrapper instead of an unresolvable `declare`),
and a fix to `gen_call` itself, which had been unconditionally rejecting
any callee that wasn't a plain `FUNCTION_DECL` — silently dropping a
call to an `extern function` from the output entirely even once its own
wrapper existed. `Edsger_v0/edsger` now links by default (`ld -static
-no-pie -e _start`), exactly like `Hoare/hoare` already does. Verified
end-to-end, not just unit-tested: a real program calling `sys_write`/
`sys_mmap`/`sys_munmap`/`sys_gettid` compiles, assembles, links, and
**runs** correctly (real stdout output, correct exit code) via
`Edsger_v0/Dockerfile.release`'s own release image — new fixture `Edsger_v0/
tests/codegen_cases/codegen_test_09_extern_syscalls.ptl`.

This was found while building `Edsger_v0/edsger` (the CLI script mirroring
`Hoare/hoare`) and while deleting the now-superseded `postulate_stage1_
v1_0_2_llvm_backend_design.md`/`postulate_stage1_v1_0_3_composites_
design.md`, which had already worked out the exact technique once for
the pre-rewrite proof of concept — preserved below rather than only in
those now-deleted files:

- **Raw syscalls have no LLVM intrinsic** — each of the whitelisted
  `extern function`s (§5.2's table: `sys_read`=0, `sys_write`=1,
  `sys_close`=3, `sys_exit`=60, `sys_openat`=257, standard Linux
  x86-64 numbers) needs to be emitted as a `call` to an inline-asm blob
  with register-constrained operands — the standard LLVM idiom for raw
  syscalls (the same technique e.g. Rust's and Zig's own freestanding
  raw-syscall paths use), and the only realistic option short of
  linking a separate hand-written stub object:

  ```llvm
  ; sys_write(fd, buf, count) -> i64
  %ret = call i64 asm sideeffect
    "syscall",
    "={rax},{rax},{rdi},{rsi},{rdx},~{rcx},~{r11},~{memory}"
    (i64 1, i64 %fd, i64 %buf, i64 %count)
  ```

  (`1` is `sys_write`'s own syscall number, loaded into the `rax` input
  constraint directly as an immediate — `rax` is both an input, the
  syscall number, and the output constraint, the return value, matching
  the real `syscall` instruction's own behavior. `rcx`/`r11` are marked
  clobbered because `syscall` itself overwrites them, an architectural
  fact, not a convention choice; `~{memory}` prevents `llc` from
  reordering surrounding memory operations across the call.)
- **`_start` becomes a plain `define void @_start()`**: calls `@main`,
  then performs the exit syscall inline-asm above with `main`'s return
  value (`0` for a `void` main), then `unreachable`. No `@main`/libc/
  crt0 convention needed — this is what lets `edsger`'s own link line
  stay exactly `ld -static -no-pie -e _start -o out out.o`, no libc
  involved, mirroring `hoare`'s own link line precisely. `_start` never
  reaches a `ret` (the process exits via the
  syscall, not by returning), so any prologue `llc` may still emit for
  it is dead code that never executes — harmless, not worth suppressing.
- **`main`'s own declared return width, not an assumed one** — `_start`
  must call `@main` at whatever width `main` actually declares (`void`
  or any atomic type, reference §6.3), zero/sign-extending the result to
  `i64` before the exit syscall only if it isn't already 64 bits wide
  (the exit syscall's own observable exit code only depends on the low
  8 bits regardless, so `zext` is fine unconditionally here, no need to
  branch on `main`'s own signedness).
- **A concrete bug shape to watch for, already hit once**: the old
  proof of concept's own array codegen initially reused the same
  `getelementptr` suffix piece for both "a runtime-computed element
  index" (`i64 0, i64 %v2`) and "a compile-time-constant element
  position" (`i64 0, i64 2`) — conflating the two produces
  syntactically valid-looking IR that compiles cleanly but fails
  `llc`'s own verifier (`'%vN' defined with type 'ptr' but expected
  'i64'`) the moment it's actually assembled, not at Postulate-level
  compile time. Edsger's own `codegen.ptl` already avoids this
  particular shape (`gen_member_addr`'s constant-index GEPs and the
  runtime-indexed array branch in `gen_addr` are two textually distinct
  code paths, never sharing a "reuse the dynamic-index piece with a
  literal appended" shortcut) — noted here so whoever adds syscall
  codegen knows the failure mode to watch for if a similar shortcut
  looks tempting there too, not because Edsger has this bug today.

Landed as a direct fix to `v1.0.6`'s own Codegen module (above), not a
new `v1.1.n` step — this was completing that module's own original,
already-scoped intent, not adding new v1-language surface.

### A self-hosting dry run against `codegen.ptl` itself (2026-08-28)

**Not `v1.1.13` itself, and doesn't close it** — recorded here as a
preliminary finding directly relevant to that step, the same way the
two checkpoints above record findings relevant to steps other than the
one that produced them. Prompted by a plain question — would
`Edsger_v0/src/codegen.ptl`, Edsger's own ~6,730-line, 304,772-byte
source, compile if fed to Edsger's own binary right now? — answered by
actually trying it, on a disposable copy, rather than reasoning about
it in the abstract.

**Two files, two very different roles — do not confuse them:**

- **`Edsger_v0/src/codegen.ptl`** is the real, shipped, unmodified
  compiler — Module 3+4 (§3), what `Edsger_v0/scripts/build.sh` builds,
  what `Edsger_v0/edsger` and `Edsger_v0/Dockerfile.release` both
  ultimately run, and what every existing fixture in `Edsger_v0/tests/
  codegen_cases/` is checked against. **Untouched by this dry run.**
- **`Edsger_v0/src/codegen_selfhost.ptl`** is a **throwaway research
  copy**, made specifically so this experiment could poke at real bugs
  without any risk to the working compiler above. It is **not**
  referenced by `scripts/build.sh`, `edsger`, either Dockerfile, or any
  test runner — nothing builds it by default, and nothing will start
  doing so by accident. It exists purely as the recorded evidence for
  the findings below; it is not a step toward being merged back as-is
  (see "What this does and doesn't mean," below, for what should
  actually happen to each fix inside it).

**Method.** `codegen_selfhost.ptl` was fed a copy of `codegen.ptl`
prefixed with a bare `namespace \Main;` line — the one syntactic
accommodation this dry run needed, since `codegen.ptl` is v0 source
(no `namespace_decl` of its own) but Edsger's parser enforces v1's
"mandatory, first" namespace declaration (reference §6.2) regardless of
what it's compiling. Failures with no usable diagnostic (three of the
five below) were isolated by bisection: feeding successively larger
*prefixes* of `codegen.ptl`'s own top-level declarations through
repeated builds to find the smallest one that broke, then — once
execution ran silently to completion without crashing but still
reported failure — by adding temporary stderr trace-byte writes at
every function entry/exit and at every existing `had_error := true`
site, removed again once the real cause (fix 5, below) was found. No
trace of that instrumentation remains in either file.

**Five real bugs found, all still present in `codegen.ptl` as shipped:**

1. **Unbounded writes into fixed-capacity `Parser`/`Sema`/`Codegen`
   arrays.** `Parser.src`/`FileBuf.bytes` (`uint8[65536]`),
   `Parser.toks_kind`/`toks_offset`/`toks_length` (`int32`/
   `uint64[20000]`), `Parser.pool` (`ASTNode[50000]`),
   `Sema.symbols`/`main`'s `symbols_arr` (`Symbol[256]`), and
   `Codegen.out`/`main`'s `out_buf` (`uint8[131072]`) are all written
   through their own tracked `_len`/`_count`/`pos` index with **no
   bounds check against the array's own declared size** — `alloc_node`
   (§3's own AST-pool description) is the clearest example:
   `&(*(*p).pool)[(*p).node_count]` with nothing stopping `node_count`
   from reaching `50000`. Real-world input the size of `codegen.ptl`
   itself overruns several of these well before reaching the file's
   own end, corrupting adjacent memory — undefined behavior, so its
   *symptom* varied run to run with the exact same input (a plain
   segfault in one run, a nonsense "sema error"/"unknown identifier" in
   another), consistent with which nearby memory a given overrun
   happened to land on. `codegen_selfhost.ptl` raises these five to
   `uint8[1048576]` (1 MiB), `int32`/`uint64[200000]`,
   `ASTNode[400000]`, `Symbol[2048]`, and `uint8[8388608]` (8 MiB)
   respectively — sized against this one dry run's own needs, not a
   general fix (see "What this does and doesn't mean," below). The same
   dry run also shrank `FileSet`/`Sema`'s `MAX_FILES` (`FileBuf[24]`,
   `uint64[24]`, `PathBuf[24]`, `*ASTNode[24]`, and the matching `>= 24`
   check) down to `[1]`, since this experiment only ever compiles the
   one self-contained file — a memory-saving choice specific to this
   dry run, not a claim that Edsger should only ever support one file.
2. **A unary-minus-wrapped literal didn't inherit its context's
   expected type.** `mut matched_rule : int64 := -1;` (real code,
   `codegen.ptl` line 2350) failed as "expected type 'int64', found
   'int32'": `check_expected`'s existing "an untyped literal adopts
   whatever integer type context expects" mechanism
   (`decorate_literal_with_expected`) only recognized a *bare* literal
   node, not a `UNARY_EXPR` (`-`) wrapping one, so the literal `1`
   silently defaulted to `int32` before the unary minus was ever
   considered. Fixed by special-casing exactly that shape in
   `check_expected` — but **only** when the expected type is a
   genuinely *signed* integer type, so the existing, deliberate v1
   tightening ("unary `-` requires a signed operand," already
   documented in `codegen.ptl` itself) still correctly rejects
   `mut x : uint64 := -1;` by falling through to the ordinary path
   unchanged.
3. **Array broadcast-init (`v1.1.12`, above) is exactly as unimplemented
   as that row already says**, confirmed by `codegen.ptl`'s own source
   actually needing it: `mut seen_arr : bool[64] := false;` and a
   dozen-plus `uint8`/`int32`/`uint64[N] := 0;` locals (including
   `out_buf`'s own 8-MiB array) all failed the same way `v1.1.12`
   predicts. Fixed **only for the `DECL_STMT` shape** (`mut x : T[N] :=
   value;`) — Sema now checks a non-array-literal initializer against
   the array's own *element* type, and Codegen evaluates the source
   value once, then either emits one `store <arraytype>
   zeroinitializer, ptr %slot` (when the source is a compile-time-zero
   immediate — the *only* shape `codegen.ptl` itself ever uses, and the
   reason a naive per-element loop had to be avoided at all: an
   unrolled loop over `out_buf`'s own 8,388,608 elements would emit
   millions of IR lines and overrun the very output buffer fix 1 just
   enlarged) or, for any other source value, a general — correct, but
   `O(n)` — unrolled loop of per-element `getelementptr`+`store` pairs.
   The plain-assignment half of broadcast (`arr := value;`, an
   `ASSIGN_STMT`, not a `DECL_STMT`) and the struct-source half
   (reference §4.1/§4.2's `mut pts : Point[4] := p;`) are **not**
   touched — `codegen.ptl` never needs either, so both are left for
   whenever `v1.1.12` itself is actually implemented, for real, as its
   own step.
4. **`Scope.bindings` (`LocalBinding[64]`, shared by `decorate_
   function` and `gen_function`) silently overflows past 64 locals in
   one function.** `codegen.ptl`'s own `main()` alone declares 101 —
   `scope_add`'s `(*(*sc).bindings)[(*sc).count] := ...` has the same
   "no bounds check" shape as fix 1, just a different array. Raised to
   `LocalBinding[256]` (and, found alongside it, `CastWarning[64]` to
   `[256]` for the same reason, though nothing in `codegen.ptl` itself
   happens to exercise that one).
5. **`gen_addr` had no case for a struct/array-*valued* function call
   used directly as a field or index base, with no intermediate
   variable of its own** — `codegen.ptl`'s own `expr_pos_tok(cast_
   warnings_arr[w].node).offset` is exactly this shape: `expr_pos_tok`
   returns a `Token` **by value**, and `.offset` reads a field straight
   off that returned value. `gen_addr`'s `FIELD_EXPR`/`INDEX_EXPR`
   cases already recurse into `gen_addr` for a non-pointer base to get
   its address, but had no case at all for a `CALL_EXPR` base, falling
   through to the function's generic "unsupported" tail (silently
   setting `had_error`, no message — the one failure in this list that
   genuinely had no diagnostic to bisect toward, hence the trace-byte
   instrumentation described under "Method," above). Fixed by giving
   `gen_addr` a `CALL_EXPR` case: evaluate the call via the already-
   correct `gen_expr` (which already knows how to materialize a struct/
   array-returning call's result, the same alloca-then-load shape
   `STRUCT_LIT`/`ARRAY_LIT` already use elsewhere in the same file),
   spill that value into a *fresh* temporary `alloca`, and hand back
   that slot's own address — the same "materialize a value to get an
   address" idiom, applied to one more case that needed it.

**The stack-limit requirement, and a recommended minimum.** Every array
fix 1 enlarges is an ordinary v0 **stack**-local (the same "big fixed
array as a local, not a heap allocation" shape §3's own rewrite section
already documents for the AST pool, `alloc_node`'s own paragraph
above) — `main()`'s own locals in `codegen_selfhost.ptl` now add up to
roughly **53–54 MiB**: the node pool alone is ≈39.7 MiB (400,000 ×
≈104 bytes per `ASTNode`, matching the ≈101.7-bytes/node figure the
original `MAX_FILES=24` design comment already measured), the output
buffer is a further 8 MiB, the three token arrays ≈3.8 MiB combined
(200,000 × 20 bytes), and the source/path/symbol buffers and everything
smaller add under 2 MiB more. That is far past the platform's ordinary
8 MiB default (`ulimit -s`), so `build/codegen_selfhost` cannot even
**start** — it segfaults immediately, on any input at all, including a
trivial one — unless the invoking shell's own stack limit is raised
*before* running it:

```sh
ulimit -s 262144   # 256 MiB — see below for why this figure, not the ~54 MiB floor
./build/codegen_selfhost < input.ptl > output.ll
```

**Recommended minimum: `ulimit -s 262144` (256 MiB).** This is the
*only* value this dry run actually exercised, successfully, end to end
(see the run outcome below) — it is a generous margin over the ~54 MiB
figure above, which counts only the fixed arrays themselves and not the
additional stack ordinary recursive-descent parsing/decoration call
depth needs on top of them. A tighter limit closer to that ~54 MiB
floor was never tried and so isn't recommended, for that reason alone —
not because it's known to fail, simply because it's unverified. This
requirement is specific to `codegen_selfhost.ptl`'s own enlarged
arrays; the real, shipped `codegen.ptl` (still at the original,
smaller capacities) has never needed a raised stack limit and still
doesn't.

**Run outcome.** With that limit set, `build/codegen_selfhost` fed the
namespace-prefixed copy of `codegen.ptl` described under "Method"
**exits `0`** and emits ≈2.08 MiB of LLVM IR text — every one of the
~6,700 lines' worth of real constructs `codegen.ptl` itself exercises,
parsed, type-checked, and code-generated successfully. `opt
-passes=verify` accepts that IR without complaint — it is valid LLVM
IR, not merely "didn't crash." Assembling it with `llc -filetype=obj`,
however, **crashes `llc` itself** (a segfault inside LLVM's own
SelectionDAG instruction selector while lowering `@main`, not a
Postulate-level error) — almost certainly LLVM's own backend struggling
with one function whose stack frame is tens of megabytes wide, the
direct consequence of fix 1's own array sizes, not a defect in the
(already-verified-valid) IR. This was not chased further: the fix is
already anticipated, not a new idea — `codegen.ptl`'s own §3 rewrite
notes above already explain that the fixed-array-as-stack-local shape
was a deliberate stand-in ("what actually blocked \[a real
pointer-linked tree\] before was reaching for heap allocation... a
large, fixed-capacity local array... produces real, individually-
addressable `*ASTNode` values with no cast and no heap involved at
all"), and the `FileSet`/`MAX_FILES` design comment quoted under
"Resolved checkpoint," above, already names `sys_mmap` as the specific,
not-yet-taken path to a heap-backed version of these exact same
buffers. Moving `codegen.ptl`'s source/token/node/output buffers from
stack locals to `sys_mmap`-backed heap allocations is expected to
remove the stack-limit requirement above *and* fix this `llc` crash in
one move, since an ordinary heap allocation doesn't inflate whichever
function requested it the way a giant local array does.

**What this does and doesn't mean for `v1.1.13`.** This dry run does
**not** close `v1.1.13` — that step needs Edsger to accept its own
*real* source (a genuine leading `namespace \Main;`, one real v1
program, no capacity workarounds) and produce a linked, running binary
from it that agrees with itself across two generations, exactly as that
row already describes. What it does establish: (a) once `v1.1.12` is
actually implemented as its own real step — not this dry run's
narrower, `codegen.ptl`-shaped stand-in — the front end and codegen
have no other *language-level* gap standing between Edsger and
compiling its own real source, since every other construct `codegen.
ptl`'s ~6,700 lines exercise already round-trips correctly; (b) fixes
1/4/5 above are real, previously-undetected memory-safety bugs in the
*shipped* `codegen.ptl`, findable only by throwing a real, large program
at it — the hand-written `codegen_cases/` fixture suite was never going
to exercise a 101-local function or a >65 KiB input — and are worth
fixing on their own merits whenever someone next touches those code
paths, self-hosting or not; (c) the LLVM backend itself, not just
Edsger, needs the already-planned fixed-array-to-heap migration before
self-hosting can get past assembling its own output. None of the five
fixes above have been ported into the real `Edsger_v0/src/codegen.ptl`
— `codegen_selfhost.ptl` stays exactly what its name says: a disposable
record of this one dry run, not a pending patch.

### Resolved: the modular, dynamic-memory rewrite (2026-08-28)

**Done, same day as the dry run above** — what the dry run identified as
the two remaining blockers (the `llc` crash, and the five memory-safety
bugs) are both closed, not by patching `codegen.ptl` in place, but by
building the real, physically-modular Edsger the dry run's own "what
this does and doesn't mean" section deferred: `Edsger_v0/src/modular/`
— genuine `namespace`/`use` files (`Edsger/{Dynamic,Lexer,Parser,Sema,
Codegen}.ptl`, `main.ptl`), and every one of `codegen.ptl`'s
fixed-capacity stack arrays replaced with real, growable, `sys_mmap`/
`sys_mremap`-backed dynamic memory. **This is now the default build**:
`Edsger_v0/scripts/build.sh` and `Edsger_v0/edsger` both target it —
`src/codegen.ptl` (the original, single-file, fixed-capacity
architecture) is left on disk, untouched, as the historical record, but
is no longer what gets built.

**The `Dynamic` module and five converted structures** — one growable
struct per element shape (no generics), each following the language
reference's own canonical `sys_mmap`(init)/`sys_mremap`(grow)/
`sys_munmap`(free) pattern (§2.8), growing in **fixed-size chunks** (not
exact-fit, not doubling) per the user's own explicit choice, to keep
the number of `mremap` calls down:

- **`DynBytes`** (`Edsger\Dynamic`) — the workhorse: per-file source
  buffers, the LLVM-IR output buffer, path/error scratch buffers.
  `FileBuf.bytes` (previously `uint8[65536]`) is now an *owned*
  `DynBytes`; every function that used to take `*(uint8[65536])`
  (~35 signatures across all four modules) now takes `*DynBytes`, with
  `(*buf)[i]`-style sized-array indexing replaced by `(*buf).ptr[i]`
  throughout.
- **`DynNodePool`** (`Edsger\Parser`, next to `ASTNode` itself) —
  replaces the AST arena (`ASTNode[50000]`, ~4.85 MiB at that size;
  `alloc_node` is now its only touch point).
- **`DynTokens`** (`Edsger\Parser`) — replaces the three parallel
  `int32`/`uint64[20000]` token arrays with one struct, all three
  regions grown together by one `dyntokens_ensure` call.
- **`DynSymbols`** (`Edsger\Sema`) — replaces `Symbol[256]`; needed for
  real, since `codegen.ptl`'s own top-level decl count already exceeds
  it.
- **`DynBindings`** (`Edsger\Sema`) — replaces `LocalBinding[64]`;
  needed for real, since `codegen.ptl`'s own `main()` alone declares
  over a hundred top-level locals.
- **`FileSet`'s file-count arrays** (`buffers`/`lens`/`paths`/
  `path_lens`/`programs`, previously fixed at `[24]`) stay fixed-size
  for now (a modest cap is enough for the handful of real module files
  Edsger itself currently has) — the per-file *content* they point to
  (`FileBuf.bytes`) is the part that actually needed to be unbounded,
  and is.

**A second real bug found and fixed while wiring this up, distinct from
the dry run's own five**: every `sys_mremap` call initially passed
`flags := 0`. Without `MREMAP_MAYMOVE` (`1`), the kernel refuses to grow
a mapping it can't extend in place and returns failure — silently
producing an invalid pointer that then corrupts memory the moment
anything reads or writes through it. This surfaced as an immediate
segfault on *any* input, the instant a real growth past the first chunk
actually happened (a small test buffer growing by tiny 4-byte chunks
had enough neighboring free address space to *usually* extend in
place, masking the bug in isolation; a 1 MiB source buffer trying to
grow essentially never does). Fixed by passing `1` everywhere `sys_
mremap` is called.

**Verified end-to-end, not just unit-tested**: `opt -passes=verify`
accepts the self-compiled IR; `llc`/`ld` succeed with **no crash**
(the dry run's own open problem); the resulting `build/codegen`
runs the full `codegen_cases/` fixture suite correctly — all 9 —
**with no raised stack limit**, unlike `codegen_selfhost` (confirming
the rewrite's whole point: heap-backed buffers don't inflate a
function's own stack frame the way fixed local arrays did). The build
itself is a real two-stage bootstrap, documented in `scripts/build.sh`'s
own header: `hoare` compiles `codegen_selfhost.ptl` (still needed,
only as a throwaway tool with a large-enough fixed capacity to read the
modular source's own files), which then compiles `src/modular/main.ptl`
into the real `build/codegen` — the binary `edsger` and the test
runners actually use, unchanged from before.

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

Once `v1.1.13` closes the self-hosting loop, Hoare (Stage 0) becomes
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
