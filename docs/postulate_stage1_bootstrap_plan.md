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
  `v1.1.3`, well after this scheme starts calling the compiler
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

**Post-rewrite generations are planned phases, not an open-ended
counter (decided 2026-08-29).** Generation `1` (Edsger proper) is
itself split into four planned sub-generations, each with its own
real theme, each closing with Edsger **recompiling itself** against
the newly-added surface, a full regression pass, a tagged
`edsger-vX.Y.Z` release, and an updated `postulate_v1_language_
reference.md` reflecting everything decided in that phase — the same
"generation bump = a genuine internal rewrite" definition already
given above, just now with four known-in-advance bumps instead of
hypothetical future ones:

- **`v1.1.n` — full syntax.** Every language-surface addition/change
  that needs neither polymorphism nor Why3: statement sugar, floats,
  `ref`, operator overloading, the module-system overhaul (`::`,
  `@shadow`, namespace-scoped resolution), `string`/`rune`, function
  types, pointer-to-const, and the smaller syntax/semantics
  tightenings §6 decided. See §4 below.
- **`v1.2.n` — polymorphism.** Generic functions and generic structs
  (monomorphized), and a final, explicit yes/no on type classes.
- **`v1.3.n` — Why3-integrated verification and safety.** The
  contract system (grammar, runtime checking), static verification via
  Why3, and the compiler-enforced heap-memory-safety system (`own`,
  automatic `valid()` tracking) — grouped together because all of it
  is either directly Why3-driven or a direct prerequisite for what is.
- **`v1.4.n` — a compiler capability, not a language feature.** Edsger
  gains the ability to compile a library unit (no `main` required),
  emit a dynamically-linkable binary, and maintain its own build cache
  (the "shadow cache" design, `temp/Edsger-cache-system.md`) so only
  the compilation units that actually need it get rebuilt.

Within each phase, the third number still just counts steps in
writing order, same as always.

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
run," below, for what `_v0` will stop meaning once `v1.1.14` actually
closes the self-hosting loop.

**Verification discipline.** Every step ships only once actually
**run** against real fixtures with checked exit codes/output, not just
"it parses" or "it compiles" — unchanged from how `v1.0.2`/`v1.0.3`
were verified. Starting at `v1.0.6`, this is refined into a
**module-by-module** discipline, not just an end-to-end one — see §3.

**Error-reporting discipline (decided 2026-08-29, starting with
`v1.1.n`).** Every phase (Lexer, Parser, Sema) today stops at its very
first diagnostic and returns immediately — real for the *shipped*
Edsger_v0, not being retrofitted onto it as its own step, but a
deliberate change for whatever gets built or substantially touched
from `v1.1.n` onward (the module-system overhaul, `v1.1.12`, rewrites
enough of Sema that it's the natural first place this actually lands):
**accumulate and report as many independent errors as possible in one
run, not just the first.**

- **Lexer**: an invalid byte or malformed literal becomes an error
  token (or the offending bytes are skipped), and scanning continues —
  never an immediate halt.
- **Parser**: real error recovery ("panic mode" synchronization — on a
  syntax error, skip forward to the next likely statement/declaration
  boundary, e.g. `;` or `}`, then resume parsing from there) so one
  syntax error doesn't hide every other one later in the same file.
  This is genuine, new parser-engineering work, not a small tweak —
  Edsger's own recursive-descent parser doesn't have a synchronization
  mechanism today.
- **Sema**: a type/semantic error doesn't abort analysis — the
  offending expression/declaration gets a placeholder/error type,
  analysis continues across the rest of the file/program collecting
  further errors, and codegen is still refused at the end if *any*
  were collected — same final outcome as today, just after seeing
  everything instead of stopping at the first thing found.
- Diagnostics accumulate into a real list (not a single `had_error`
  flag plus an immediate `return`), reported together at the end.

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
  to its own later step (originally planned as `v1.1.1`; since
  reorganized again, 2026-08-29, into the full "shadow cache" design,
  `v1.4.3` below, once real `.pto`/`.proof` artifacts exist to key it
  against) rather than attempted alongside everything else `v1.0.6`
  already has to get right.
- **Real optimization (old `v1.0.5`) moves to after the rewrite.**
  Nothing about `opt` integration depends on anything `v1.0.6` adds —
  it was only ever grouped with the rewrite because both rode on the
  same LLVM IR switch (§2 still explains that shared mechanism) — but
  it competes for attention with the rewrite for no real benefit, and
  is genuinely lower-priority than making the intermediate compiler
  pleasant to write Edsger's own later stages in. It becomes `v1.1.1`.
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
   from-scratch design problems** — `opt` (now `v1.1.1`) and per-module
   compilation (dependency resolution folded into `v1.0.6`, the caching
   half now `v1.4.3`) both ride on LLVM IR existing at all; neither
   needed designing before this switch, and neither would have been
   cheaper to build against a NASM-text backend first and then redo for
   LLVM immediately after.

**Adopting LLVM IR did not require reasoning about SSA form.** The
straightforward, standard technique (what `clang` itself does at `-O0`)
is one stack slot (`alloca`) per local, a load before every read, a
store after every write — letting `opt`'s `mem2reg` pass promote those
to registers automatically once optimization is actually turned on
(`v1.1.1`). This changes only which fixed-template text codegen
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
  that's the shadow cache, `v1.4.3`). Path resolution for the default 1:1 mapping and
  `@autoload` patterns is relative to the compiler process's **current
  working directory** (`sys_openat(AT_FDCWD, ...)`, exactly the
  mechanism `#include` already used) — no command-line argument support
  is added for this; the entry (`\Main`) file's own text still arrives
  on stdin exactly as today, and everything it `use`s is resolved from
  there. Whether Edsger ever needs real `argv`/`argc` input of its own
  is left for whenever `main(argv, argc)` (`v1.1.4`) actually gets
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
  waits for `v1.1.3`, since Edsger's own source has no float type to
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

### Generation 0 — proof of concept through the rewrite

| Version | Adds | Why here |
|---|---|---|
| `v1.0.1` | **Retired.** Was `#include` (relative-path resolution, recursive splice, include-once, cycle detection). Superseded in full by namespaces/`use`/`@autoload` (§6.2), built as part of `v1.0.6`. Its own design doc (`postulate_stage1_v1_0_1_include_design.md`, describing a mechanism no longer part of the language) has since been deleted — the one piece of it with lasting value, adding `sys_openat`/`sys_close` to the `extern function` whitelist to unblock file I/O, is already folded into `postulate_v1_language_reference.md` §5.2's own table and `postulate_v0_language_reference.md`'s own extern-table note. | See "Revision note" above. |
| `v1.0.2` | **Done.** Codegen backend switch: emit LLVM IR instead of x86 NASM text; `llc` replaces `nasm`. Same scalar-only feature set as before — a backend swap, not a feature addition. Its own design doc (`postulate_stage1_v1_0_2_llvm_backend_design.md`) has since been deleted; the one piece of it not yet carried into Edsger — the extern/syscall inline-asm and `_start` emission technique — is preserved in the "Tracked checkpoint: extern/syscall calls and `_start`" section below, not lost. | Foundation for composites, optimization, and per-module compilation alike — §2. |
| `v1.0.3` | **Done.** Composite (struct/array) parameters and return values in Stage 1's own codegen — v0 parity. Structs, arrays, broadcast-init (scalar **or** struct source, both at decl-init and at plain assignment — reference §4.1/§4.2, `v1.1.7` below), pointers (scalar and composite pointees, including self-referential struct fields), and the by-value calling convention. Its own design doc (`postulate_stage1_v1_0_3_composites_design.md`) has since been deleted; its broadcast-init scope finding and its `_start`/`main`-return-width note are preserved in `v1.1.7` and the "Tracked checkpoint" section below, respectively. | Implemented directly against LLVM IR's native aggregate types — §2. |
| `v1.0.4` | **Retired.** Was true separate compilation, designed against `#include`'s textual-splice model. Never implemented. What it was trying to achieve is now the namespace system's own design property (§6.2c), not a separate mechanism to build. Its own design doc (`postulate_stage1_v1_0_4_separate_compilation_design.md`, describing a mechanism the current language design doesn't need) has since been deleted — nothing in it survived its own retirement, since none of it was ever built. | See "Revision note" above. |
| **`v1.0.5`** *(placeholder — see `v1.1.1`)* | *(retired slot — optimization moved to `v1.1.1`; kept blank rather than reused, so no future step is ever ambiguously "the same number as something else.")* | — |
| **`v1.0.6`** | **The Edsger rewrite. Generation `0` ends here.** Namespaces/`use`/`@autoload` (dependency resolution only, no caching); `char` + `as`; pointer arithmetic/`*void`/`uintptr`/`sizeof`/`lengthof`; full modular architecture (lexer/AST/parser/semantic-analyzer-and-type-checker/codegen as real, separate modules; pointer-linked `ASTNode` tree replacing the index arena). Built and verified **module by module**, each module covering the whole feature batch, each checked by hand before the next starts (§3). Its own design doc (`postulate_stage1_v1_0_6_edsger_design.md`) has since been deleted — it described *how* to build what this row and §3 above already fully describe, and Edsger's own shipped source (`Edsger_v0/src/*.ptl`) is now the more authoritative, more precise record of the actual result. | §1/§3 — the module system is the architecture's own foundation, not an add-on to it; `char`/`as`/pointer arithmetic front-loaded so Edsger's own later stages are comfortable to write. |

### Generation `v1.1.n` — full syntax (reorganized 2026-08-29)

Everything language-*surface* — no polymorphism, no Why3, no caching.
Closes with Edsger recompiling itself against the whole new surface,
full regression, a tagged `edsger-vX.Y.Z` release, and an updated
`postulate_v1_language_reference.md`. Several rows below fold in
decisions §6 (further down) records in full detail — this table gives
each one a step number and a place in the build order; §6 stays the
place to read the actual reasoning.

| Version | Adds | Why here |
|---|---|---|
| **`v1.1.1`** *(generation `1` begins — Edsger proper)* | Optimization turned on: each module's LLVM IR routed through `opt` at a chosen level before `llc`. | Moved here from the old `v1.0.5` — rides on the LLVM IR switch (§2), doesn't compete with the rewrite for priority, and doesn't depend on or block anything else in this phase; verified by re-running the full fixture suite under optimization. |
| `v1.1.2` | Statement sugar: `elseif` — as a **real, flat n-way branch construct**, not sugar for nested `if`/`else` (§6, reversing §4.3's current text) — `break`/`continue` (§4.6), compound assignment `:+ :- :* :/` (§4.2), `++`/`--` (§4.2a). No `switch`/`match` — considered and rejected, redundant once `elseif` is a real n-way branch. | Pure desugaring plus one semantic reversal, no new types — deliberately left out of `v1.0.6` (its own note) since it has no dependency relationship to that batch. |
| `v1.1.3` | **Done, 2026-08-31 (including based-form).** Floating point: `float32/64`, `ufloat32/64`, literals, `+ - * /`, comparisons incl. NaN, `**` (exponent, negative-exponent sign bug found and fixed the same day — see the `**` writeup below), `_/` (root, desugars to `**`) (§2.4, §3.2) — **plus** based-form float literals (§6): `based_form ::= digit+ "n" value_digit+ "." value_digit+ (exponent)?` -- the fraction is MANDATORY (unchanged from the original design: both the integer and fractional value-digit runs always have to be written out), only the exponent is optional; exponent marker `p`/`P` for base 16 (digit-alphabet collision with `e`/`f`), `e`/`E` otherwise, always plain-decimal digits, and the exponent CAN be negative (`2n1.0e-2` = 0.25). `16nFp3` (an exponent with no fraction at all) is deliberately NOT a float literal -- it lexes as based-form INTEGER `16nF` followed by an unrelated `p3` token, a parse error in any real expression position (an earlier same-day attempt made this legal by decoupling the exponent from the fraction entirely; reverted per explicit correction -- the fraction has always been required and stays required). Implementation reuses bases 2/8/16's own power-of-two property (`digits * base^exp` is an exact BIT SHIFT there, `based_float_to_bits`) rather than needing arbitrary-radix decimal-style scaling; base 10's based form reuses the plain-decimal path outright. Also found and fixed a real, independent lexer bug the float extension exposed: based-form value-digit scanning always accepted the full hex alphabet regardless of the declared base, which silently swallowed base 10/8/2's own `e`/`E` exponent marker as one more mantissa/fraction digit (`10n9.5e2` would otherwise never reach the exponent at all, `e` always consumed as a bogus extra fraction digit first) -- value digits are now restricted to what's actually valid for the declared base (`is_value_digit_for_base`), the ordinary convention every other language's based-integer literals already follow. **Fractional-exponent `**`/`_/`, also done, 2026-08-31**: a genuinely non-integer exponent (`x ** 0.5`, and `_/`'s own desugared `x ** (1.0/n)` for any n other than +-1 — meaning `_/` was NEVER actually correct at runtime before this, only ever silently wrong once a real fractional exponent reached the old truncate-via-fptosi path) now computes a real `pow(x, y) = 2^(y*log2(x))`, built from scratch (`gen_log2_f64`/`gen_exp2_f64`/`gen_float_pow_frac`, Codegen.ptl): IEEE-754 bit tricks extract x's own exponent/mantissa with no division, a 10-term atanh series covers log2 of the [1,2) mantissa, a 13-term Taylor series covers 2^f of the [0,1) fraction, and the integer part of the exponent folds back in as an exact bit-shift -- lands within 1-2 ULP of the true double-precision result (checked against Python's own `**` first). Only used once the exponent is confirmed non-integer (computed branch-free, both paths always run, `select`ed on that check) -- an integer-valued exponent still goes through the older, exact multiply-loop path, no reason to approximate when an exact answer is already cheap. `x < 0` with a fractional exponent yields a quiet NaN (mathematically undefined, matching `pow`'s own standard convention); `x == 0` follows the ordinary 0.0/+inf convention by sign of the exponent. Two real, independent bugs found and fixed getting here: (1) a large decimal constant (`ln(2)`/`1/ln(2)`, ~16-17 significant digits) written directly as a literal hit this exact compiler generation's own confirmed front-end hang bug (mask32()/inf_exp_bits()'s own long-standing workaround) -- fixed by building both bit patterns from small (<16) literals, nibble by nibble, same technique those existing helpers already use; (2) `_/`'s own desugaring (`n _/ x == x ** (1.0/n)`) built its `1.0` constant as a synthetic FLOAT_LIT with no real source text behind it, and Codegen's ordinary float-literal path always reads a literal's VALUE from its own source text -- silently parsed as `0.0` instead of `1.0`, so `2.0 _/ 4.0` was actually computing `4.0 ** (0.0/2.0)` (i.e. `4.0**0.0` = 1.0) the whole time, not `4.0 ** 0.5`. Fixed via an explicit synthetic-literal marker (`op_type := 999` on that one node) Codegen checks for before ever touching source text. | Self-contained type family; reuses `as` from `v1.0.6`. The based-form extension rides on the same lexer machinery, no reason to split it into its own step. |
| `v1.1.4` | `main(argv, argc)` two-parameter form; atomic-only `main` return type, compiler-enforced (§6.3). | Needs `**char`/pointer-array understanding from `v1.0.6`'s pointer arithmetic; deliberately not pulled into `v1.0.6` itself (its own note) since `@autoload` already covers Edsger's own near-term file-resolution needs. |
| `v1.1.5` | `ref` parameters (§5.3a) — **minus** the misleading "may not also be a composite type" note (§6: deleted outright, since a parameter being both `ref` and by-value was never reachable to begin with — there's no syntax to mark by-value explicitly). | Independent of the above; a calling-convention addition, not a type addition. |
| `v1.1.6` | Operator overloading (§5.4) — **explicitly confirmed** (§6): the two operands of an overloaded operator need not be the same type (`operator ==(a: PointA, b: PointB)` is legal); §5.4's own "parameter-type pair" wording already implied this, now stated outright. | Needs nothing new beyond ordinary function-checking machinery. |
| `v1.1.7` | Array **broadcast-init and broadcast-assignment** (reference §4.1/§4.2): a single expression whose type exactly matches an array-typed `mut`/`const`/`lvalue`'s own element type — a scalar, **or a struct exactly matching an array-of-that-struct's element type** (`mut pts : Point[4] := p;`, not scalar-only) — as a `decl` initializer or a plain `:=` right-hand side, coerced/copied exactly once and that one value stored into every element (never re-evaluated per element). Already real, working v1 behavior once — Stage 1's own pre-rewrite proof of concept implements both the scalar and the struct-source shape, at both decl-init and assignment (`v1.0.3`'s own composite work; the struct-source shape was itself a mid-implementation discovery there, cross-checked directly against `Hoare/src/sema_stmt.asm`'s `check_array_broadcast_compatible` after an initial, too-narrow "scalar only" assumption) — but never carried into Edsger's Sema/Codegen: `v1.0.6`'s composite-type round has no broadcast path of any kind. A source whose type doesn't exactly match the element type must be a codegen/Sema error, not a silent miscompile (see "Tracked checkpoint," below, for the GEP-index-shape bug this exact gap already caused once). | Small and fully self-contained — depends only on `v1.0.6`'s existing array-type support. |
| `v1.1.8` | **Pointer/type-system tightenings (§6)**: pointer-arithmetic `+` becomes non-commutative (`p + n` valid, `n + p` a type error — `i[p]` no longer means anything, `p[i]` unaffected); struct layout's default changes from packed to natural/ABI alignment (real Codegen impact: `Edsger_v0/src/modular/Edsger/Codegen.ptl` stops emitting `<{ ... }>` packed struct types); `sizeof`/`lengthof` default (unanchored) type becomes `uintptr`, not bare `uint`, and a value that doesn't fit an explicitly-anchored narrower type is a hard compile error, not a warning; a compiler warning (not an error) when a hand-written anchored numeric literal overflows its own anchor's implied width. | Grouped: none of these interact with each other, but all are small, self-contained type-system/codegen corrections with no dependency on anything else in this phase. |
| `v1.1.9` | **Text handling (§6)**: a real, native `string` type (a string literal anchors to either a fixed `char[N]` or a real `string`, same anchor family as numeric literals); `rune`/`rune_string` for UTF-8 — `rune` itself lives in `std` (`struct rune { bytes : uint8[4]; }`, original UTF-8 bytes by value, no pointer, no length field), but the lexer gains two core mechanisms for it: a multi-byte `'...'` literal becomes an untyped constant restricted to the char/rune family (never a plain integer type), and string-literal decoding extends to per-code-point `rune[N]` array literals via the same string-anchor mechanism. | `string`/`rune` share the same literal-anchoring extension to §3.7/§1.5; sequenced together since one lexer change (multi-byte-literal handling) serves both. |
| `v1.1.10` | Function types, **non-generic**: `(a : int, b : int) -> int`, a `pure` variant (`pure (a : int) -> int`), always a reference to an existing *named* function — no anonymous/lambda functions or closures anywhere in v1 (§6: a captured-by-reference local outliving its stack frame is exactly the hazard the memory-safety model below rules out; reasoning about an unknown callback formally needs higher-order specs v1's contract system doesn't have). `->` reused deliberately for the return-type separator despite also meaning pointer-dereference (below) — no grammar ambiguity, purely positional (type position vs. expression position), and simpler than reusing `:`. | Self-contained type-system addition; deliberately excludes closures so it never touches the memory-safety design (`v1.3.n`) at all. |
| `v1.1.11` | `->` as implicit pointer dereference (`p->field` for `(*p).field`), postfix, same precedence tier as `.`/`[]`/`()`. Pointer-to-const: `const` gains a second position in a pointer type (`*const T`, "pointee is const", vs. today's `const p : *T`, "binding is const") — reuses the existing keyword, no new one. | Both are small, self-contained pointer-syntax additions; sequenced after function types since both also touch `->`/pointer-type parsing. |
| `v1.1.12` | **Module system overhaul (§6)**: file discovery changes from "symbol name → filename" to "namespace path → directory, scanned for the symbol" (closes the "one file per symbol" default that made a real many-function module only work by accident, via flat visibility); new `@shadow` directive (real file-level symbol/sub-namespace override, `verified`/`unverified`-aware, `\Main`-only); symbol resolution becomes genuinely namespace-scoped (Sema builds a real per-namespace symbol table, closing today's "effectively flat and global" gap); namespace-level `use` gains `as` aliasing; new `::` separator (`\` for namespace segments, `::` for "everything after this is a symbol name," used in both a bare individual-symbol `use` and in-code prefixed access) — considered and **rejected** a namespace/symbol-name collision restriction, since `::` vs. `\` already disambiguates without it. **Also where the error-reporting discipline (above) first actually lands**: since Sema's symbol table is already being rebuilt from scratch here, it's built to accumulate every error it finds (unresolved symbol, ambiguous `use`, duplicate declaration, ...) rather than stopping at the first one, and the Parser gains real panic-mode synchronization at the same time, needed anyway once a file-discovery error partway through one `use` shouldn't block finding syntax errors elsewhere in the same file. **The Sema-accumulation half of this was pulled forward and delivered 2026-08-31** (see "Implemented: Sema multi-error accumulation" below), driven by the user's own explicit IDE-diagnostics goal rather than waiting for the rest of this row's own module-system work — the module-system pieces themselves (`@shadow`, `::`, namespace-scoped resolution) were already independently in place before that pull-forward, confirmed via this same round's black-box testing. | The single largest item in this phase — touches file discovery, Sema's symbol table, and lexer/parser grammar together, so it's sequenced as one step rather than split, to avoid half-migrating the module system. |
| `v1.1.13` | Nested block comments (`/* */` gains real nesting — depth counter, matches OCaml/SML/Rust/Swift/D rather than C's non-nesting behavior; a `*/` that would take the counter negative is a lexer error, not reinterpreted as `*`/`/`). | Purely lexical, no dependency on anything else in this phase; sequenced last among the small items simply because it was the last one reviewed. |
| `v1.1.14` | Self-hosting closure, phase-1 checkpoint: Edsger recompiles itself (Hoare → Edsger₁ from source; Edsger₁ → Edsger₂ from the same source; Edsger₂'s output agrees with Edsger₁'s) against the **full** syntax surface above, full regression against every existing fixture, tagged `edsger-vX.Y.Z` release, updated language reference. | The actual bootstrap goal (`Stage1/README.md`'s opening line) for this phase — only meaningful once the phase's full surface exists, since Edsger's own source will by then be free to use most of it. |

*(Documentation-only items from §6 — no compiler behavior, so no step
number: removing the misleading `ref`-parameter note above already has
one, but the `std` naming convention note and the `sys_exit`/
`sys_exit_group` naming swap are just recorded facts for whenever
`std` and this table's own prose respectively get written — see §6.)*

### Generation `v1.2.n` — polymorphism (new phase, added 2026-08-29)

Reverses the earlier "generics deferred to Noam alongside OOP" call —
see §5. Closes the same way: self-hosting recompile, regression,
release, updated reference.

| Version | Adds | Why here |
|---|---|---|
| `v1.2.1` | Generic functions, monomorphized (§6): a type parameter list `<T, ...>` on a function declaration only (never at a call site — no C++-style angle-bracket ambiguity, since a declaration is never expression-parsing context); ordinary calls infer every type parameter from the arguments; a type parameter appearing **only** in the return type makes the turbofish (`::<T>`) mandatory at **every** call, including one assigned straight into an explicitly-typed `mut`/`const` — deliberately never inferred from surrounding/expected-type context, so Sema only ever needs forward inference from arguments or an explicit turbofish, never expected-type propagation through arbitrary expressions. The compiler tracks every distinct instantiation actually used and Codegen emits one specialized LLVM function per instantiation — no runtime dispatch, consistent with the language's existing "no hidden runtime cost" precedent everywhere else. | Needs nothing from `v1.1.n` specifically, but sequenced first in this phase as the simpler of the two polymorphism features. |
| `v1.2.2` | Generic structs, monomorphized (§6): `struct Vector<T> { data : *T; ... }`, instantiated as an ordinary type (`Vector<int32>`) — always type position, same no-ambiguity reasoning as function type parameters. Composes with `v1.2.1` naturally (a generic function can take/return a generic-struct-typed parameter, one shared `T`). Explicitly confirmed: multiple type parameters need not resolve to distinct concrete types (`Dictionary<int32, int32>` is valid). Motivating case: `Edsger_v0`'s own `Dynamic` module (`DynBytes`/`DynNodePool`/`DynTokens`/`DynSymbols`/`DynBindings`) — five hand-duplicated growable-buffer structs that could become one `DynArray<T>` once this lands. | Depends on `v1.2.1`'s own monomorphization machinery; not attempted first since function generics are the simpler case to get right. |
| `v1.2.3` | Diagnostic-quality requirement (§6), applying to both rows above: a monomorphization failure must report **both** the triggering call/use site (file:line — where the user actually needs to fix something) **and** the specific line inside the generic definition where the failure occurs, plus the generic entity's name and the concrete type(s) it was instantiated with — explicitly modeled on Rust's own two-location template/generic diagnostics, explicitly **not** on C++'s notoriously unreadable, deeply-nested template error messages. | Not a separable feature — a cross-cutting quality bar for `v1.2.1`/`v1.2.2`'s own error paths, called out as its own row so it isn't silently skipped. |
| `v1.2.4` | Self-hosting closure, phase-2 checkpoint, same discipline as `v1.1.14`. | Closes this phase the same way every phase closes. |

**Type classes (bounded/constrained generics) are explicitly not
scheduled above — but must still be explicitly decided, one way or the
other, before v1 is considered finished** (§6, the user's own explicit
instruction): a real, materially larger design layer (bound
declarations, constraint checking, coherence rules) on top of plain
generics, deliberately set aside during this reorganization rather
than guessed at. Whoever closes out `v1.2.n` needs a row here — even
if that row just says "decided: no" — not silence.

### Generation `v1.3.n` — Why3-integrated verification and safety

The contract system, static verification, and heap-memory safety,
grouped together because all of it is either directly Why3-driven or
a direct prerequisite for what is. Closes the same way as every other
phase.

| Version | Adds | Why here |
|---|---|---|
| `v1.3.1` | Verification contracts, part 1: grammar, all seven contextual keywords (`requires`/`ensures`/`invariant`/`decreases`/`old`/`result`/`last`), full semantic validation (§7.1–§7.2, §7.6–§7.6b, §8.1) — **plus** (§6): `decreases` becomes mandatory on **every** recursive function, not just `pure` ones (symmetric with `while`'s own existing mandatory-`decreases` rule); a separate function-level `invariant` concept was considered and **rejected** — a function's own `requires`/`ensures`, used inductively with `decreases` as the well-founded measure, already is the complete recursive-correctness proof obligation in the Why3/Hoare-logic tradition this language follows, matching how Why3 itself has no function-invariant concept either. Zero runtime cost — a normally-compiled program emits no contract code at all. | The bulk of the contract system's complexity isolated from codegen risk; everything from `v1.1.n` needs to exist first since contract expressions can mention any of it. |
| `v1.3.2` | Verification contracts, part 2: the opt-in checked-build codegen mode (§7.3–§7.5) — runtime assertions at every specified checkpoint, halt-with-diagnostic on failure. | Split from `v1.3.1` deliberately: parsing/checking a contract correctly and *emitting code* for one are separably testable, and this is the riskier of the two. |
| `v1.3.3` | Static verification: the Why3/WhyML translation path and `postulate verify` tool (§7.8) — modular, axiom-per-`use`d-contract, `verified`-prefix-aware, incremental per `v1.4.n`'s own shadow cache. Also where the cache's own remaining open questions (`.proof` validity relative to `unverified`-trusted axioms; a compiler-generation/build-identity component in the cache key) get resolved. | Needs `v1.3.1`'s contract grammar/semantics; entirely optional and separate from the default build, so it can land after everything the default pipeline needs. |
| `v1.3.4` | Bounds-checking diagnostic build (§2.7b) — array indexing checked against `lengthof` in an opt-in build. | Same opt-in-diagnostic-build mechanism `v1.3.2` already built; reuses it rather than inventing a second one. |
| `v1.3.5` | **Compiler-enforced heap memory safety** (§6, the largest single item in this phase): one new type qualifier, `own *T` (owning pointer, vs. plain `*T`, now explicitly non-owning/observing), plus fully-automatic compiler-inserted verification, never programmer-written contracts — a single, address-keyed ghost map (`valid : address -> bool`) the compiler's own Why3 translation maintains and checks at every allocation, free, and dereference. Linear consumption of `own *T` enforced on every control-flow path (freed, returned, passed on, or stored into an `own *T` field — never left unconsumed or overwritten). A plain `*T` is verified as truly non-owning automatically too (never freed, never retained past its call) — the same check that also catches classic stack-pointer escape for free, and (`own` typed only by the allocating `std` wrapper, never by `&local`) can never apply to a stack address by construction. Composes with pointer-to-const (`v1.1.11`): `own *const T` is coherent. Closes the use-after-free gap a leak/double-free-only design would leave open, since `valid` is keyed by address, not by which pointer value/type refers to it. Explicitly flagged for precise definition at implementation time, not guessed now: exactly what "stored somewhere that outlives the call" means for a struct field / global table / handed to another function. | Depends on `v1.3.3`'s own Why3 pipeline directly — this is the pipeline's own memory-model instrumentation, not a separate mechanism bolted alongside it. Rejected alternatives (full Rust-style borrow checking; a pure hand-written-convention predicate) are recorded in §6, not repeated here. |
| `v1.3.6` | Adversarial test coverage (§6): deliberate fixtures that leak allocated memory on purpose and deliberately issue a use-after-free, expecting the compiler to **reject** them — not a "does it compile" smoke test, a confirmation that `v1.3.5`'s guarantees actually hold. | Only meaningful once `v1.3.5` exists; the user explicitly asked for this once Edsger's final v1 exists. |
| `v1.3.7` | Self-hosting closure, phase-3 checkpoint, same discipline as `v1.1.14`/`v1.2.4`. | Closes this phase the same way every phase closes. |

### Generation `v1.4.n` — a compiler capability, not a language feature

Not new v1 *syntax* — this phase changes what Edsger the *tool* can do,
requested explicitly as its own generation because it's a genuinely
separate concern from the three phases above.

| Version | Adds | Why here |
|---|---|---|
| `v1.4.1` | Edsger can compile a **library unit**: no `main` required, output is a real object/binary meant for **dynamic linking**, not a standalone, statically-linked executable (§6.3's `_start`/`ld -static -no-pie` path stays the *default*, `main`-having case; this is a second, explicit mode). | Prerequisite for the `.pto` generation below — a `.pto` describes a compiled unit's own public interface, which presupposes compiling something that isn't necessarily a whole, linkable program. |
| `v1.4.2` | `.pto` generation: Edsger emits a compiled unit's own public interface (types, function signatures, contracts) as a `.pto` file, the same artifact shape `temp/Edsger-cache-system.md`'s own "Shadow Cache" sketch and `postulate_v1_language_reference.md` §6.2c's caching design already assume exists. | Needs `v1.4.1`'s no-`main` compilation mode — a `.pto` is exactly the interface of a library unit. |
| `v1.4.3` | The shadow cache itself (`temp/Edsger-cache-system.md`'s design, reused rather than reinvented): a `.pst_cache/` (or equivalent) tree keyed by **content hash**, not timestamp, storing each compiled unit's `.pto` (interface), `.proof` (Why3 verification cache, `v1.3.3`), and `.hash` (source + dependency-interface hashes) — recompiling (and, separately, re-verifying) only the units whose own hash or whose *interface*-hash-relevant dependencies actually changed since the cache was last written. This absorbs and completes what the original plan's own `v1.1.1` ("skip recompiling an unchanged module") was reaching for, now built against the real `.pto`/`.proof` artifacts this phase produces rather than attempted early, before those existed. | Depends on `v1.4.2` (needs `.pto` to exist as the thing being cached) and `v1.3.3` (needs `.proof` to exist as the other thing being cached) — this is why it's sequenced in its own late phase rather than attempted right after the rewrite, unlike the original plan's own `v1.1.1` guess. |
| `v1.4.4` | **Generalize the syscall interface, breaking its current platform lock-in** (flagged 2026-08-31, during the `-O`/`opt` discussion above, once it surfaced how much of the pipeline already silently assumes one exact platform): today, `extern function`'s "fixed, closed list of symbol names" (§5.2) is raw Linux x86-64 syscalls only — hardcoded syscall numbers, Codegen's `gen_syscall_extern`/`is_syscall_safe_type` lowering straight to an inline-asm `syscall` instruction under the Linux SysV syscall register convention, and a single `-mtriple=x86_64-unknown-linux-gnu` hardcoded directly into the `edsger` CLI script rather than read from anywhere. Replace this with a portable OS-primitive layer: programs keep calling the same `extern function` names/signatures they already do (`sys_read`/`sys_write`/`sys_mmap`/... or a renamed equivalent), but Codegen picks the actual lowering per target — raw syscall instruction plus its own per-architecture number table for platforms that have a stable raw-syscall ABI (Linux x86-64 today, Linux ARM64 as the first real second target), and a libc/platform-call-based lowering for platforms that don't expose one at all (macOS/Windows have no stable raw-syscall interface; everything goes through `libSystem`/Win32 instead) — selected from an actual target triple threaded through the CLI, not baked in once at a single call site. | Same "compiler capability, not language feature" character as the rest of this phase — the `extern function` surface a program writes against doesn't change, only Codegen's backend-selection logic does. Sequenced here (not earlier) because it directly builds on `v1.4.1`'s own no-`main`/non-`-static`-executable compilation mode, which already has to stop assuming there's exactly one linkable-executable shape — a portable target-triple concept and a portable syscall-lowering table are the same underlying problem surfacing twice. Deliberately **not** pulled into the current generation: this is an architecture change orthogonal to everything `v1.1.n`–`v1.3.n` are actually trying to land, and the concrete trigger for writing it down now was noticing the `-mtriple` hardcoding while wiring up `opt`, not a present need to act on it. |
| `v1.4.5` | Self-hosting closure, phase-4 checkpoint, same discipline as every earlier phase's own closing row — plus confirming the shadow cache itself correctly skips recompiling/re-verifying Edsger's own unchanged modules on a repeat self-compile. | Closes this phase, and this plan's originally-scoped four generations, the same way every phase closes. |

### Decided checkpoint: struct-field layout (resolved 2026-08-29)

`v1.0.3`'s composite sub-pass represents struct fields packed, with
zero padding between them — matching v0's own language-level layout
guarantee exactly (`postulate_v0_language_reference.md` §2.6) via
LLVM's native packed struct type. This was originally left as an open
placeholder here ("explicitly not decided now"), to make sure it got a
real look before `v1.0.6` closed out the still-single-file
proof-of-concept era rather than being silently carried forward as
permanent — it has now been looked at and decided:

**v1's default struct layout changes from packed to natural/ABI
alignment.** Most target ABIs (POSIX included) expect aligned struct
layout; packed was only ever v0's own choice, not a requirement v1
needs to inherit. The compiler is free to reorder fields to minimize
padding (the language does not guarantee declaration order = memory
order once this lands). **Packed layout itself doesn't disappear from
the roadmap** — v2/Fothi (bare-metal, raw hardware layout — see
`project_postulate_roadmap.md`'s own Fothi scope) brings it back as an
explicit, opt-in annotation on a `struct`, never the default there
either.

**Done, 2026-08-30, in `Edsger_v1/src/modular/`** (the v1.1.n rewrite's
own copy — see that plan section below): `Codegen.ptl`'s `gen_struct_
types` now emits a plain, natural-alignment LLVM struct type (`{ ... }`,
no angle brackets) instead of the old packed `<{ ... }>` form. Field-
reordering-for-minimal-padding landed alongside it, in `Sema.ptl`'s own
`compute_struct_size` (v1.1.13): a struct's own FIELD_DECL chain is
sorted once, in place, by descending alignment (ties broken by
descending size, then original declaration order for determinism) —
provably optimal padding-wise whenever every alignment involved is a
power of two, which is always true here. The reordering is a single
in-place relink of `first_child`/`next_sibling`, so every existing
consumer (Codegen's own field-type emission, GEP-by-position, STRUCT_
LIT's by-name field lookup) picks it up with no further change, since
field access is always by name in this language, never by position.

**Opt-out keyword, decided 2026-08-30, not yet implemented:** a
`struct` that needs its declared field order preserved exactly (memory-
mapped I/O, wire formats, FFI/ABI-fixed layouts) will be markable
`ordered struct Name { ... }` — an adjective prefix matching the
existing `mut`/`const`/`pure`/`ref` modifier style, chosen specifically
because it says exactly what it does (fields stay in the order
written) without overloading a term already used elsewhere (`direct`
and `sequence` were both considered and rejected: `direct` reads as
memory/addressing-related without a name of its own to justify that,
and `sequence` is a noun where every other modifier here is an
adjective). **Implementing `ordered` itself is out of scope for the
v1.1.n rewrite** — per `project_postulate_roadmap.md`'s own Fothi
scope, it belongs to v2/Fothi alongside packed layout's own opt-in
return, since both are bare-metal/hardware-layout concerns; this row
only fixes the NAME so Fothi's own design doesn't have to re-litigate
it later.

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

### Root-caused and fixed: the "large literal hangs the compiler" bug (2026-08-31)

Real, user-facing, and had been merely worked around (never actually
diagnosed) every time it came up earlier in this same session: an
ordinary literal like `mut x : uint64 := 5000000000;`, written in
someone else's Postulate PROGRAM (not Edsger's own source), made
`edsger` itself hang compiling it — empirically confirmed still
running past 20 seconds (`timeout 20` killing it) before this fix, 26ms
after. Root cause: `int64_to_uint64`/`uint64_to_int64` (`Sema.ptl`/
`Parser.ptl`) were both O(n) COUNTING loops (`while (steps>0) {
result+1; steps-1; }`) — not O(digit count), O(the literal's own
VALUE) — and `Parser.ptl`'s own `parse_array_size`/the general INT_LIT
parse path both run every literal's computed value through exactly one
of these on every single parse, unconditionally. Nothing to do with
lexing/parsing text itself (already O(digit count), always fast) —
purely this one conversion step, applied to a value that had already
been computed correctly and efficiently by `compute_int_value` one
line earlier.

Fix: both functions are now a single-line `n as uint64`/`n as int64` —
int64 and uint64 are both plain 64-bit `i64` at the LLVM level (no
separate signed/unsigned integer type there), so `gen_cast`'s own same-
width branch already treats this pair as a complete no-op cast (`sw ==
dw` → `return src_op`, no instruction emitted at all) — an O(1) bit
reinterpretation was available the entire time via ordinary `as`;
nobody had tried it. Incidentally also closes a second, latent bug the
old loop had: for a NEGATIVE `n`, `steps > 0` was false immediately, so
`int64_to_uint64` always silently returned 0 instead of `n`'s own
two's-complement-reinterpreted (large) uint64 value — never observed
triggering in practice (no call site seems to have passed a negative
value), but `as` doesn't have the bug at all regardless of whether it
was ever hit.

**Where exactly this lineage of hacks is legitimate vs. leftover** (the
user's own explicit request to sort out, once the fix above surfaced
just how far back this pattern actually goes): a `grep` across the
whole repo found the identical counting-loop shape in EVERY generation
back to `Stage1`, and in every Edsger v0/v1 single-file historical
snapshot (`codegen.ptl`, `sema.ptl`, `parser.ptl`, `lexer*.ptl`,
`codegen_selfhost.ptl`) — but only two things actually matter for
whether it's fixable:

- **Compiled by Hoare → the loop is genuinely required, not a stylistic
  leftover.** Confirmed directly (not assumed): feeding Hoare a file
  using `x as uint64` fails with `parse error: ... found IDENT as` —
  Hoare's own lexer doesn't even tokenize `as` as a keyword. Every file
  Hoare compiles (`Stage1/src/*`, every Edsger-generation single-file
  snapshot including `codegen_selfhost.ptl` — `Edsger_v0/scripts/
  build.sh`'s own stage 1) has no alternative and correctly keeps the
  loop. This includes `codegen_selfhost` itself: it's the tool that
  compiles the REAL modular source (stage 2 of both Edsger_v0's and
  Edsger_v1's own `build.sh`), but `codegen_selfhost` itself is built
  BY Hoare, so its own internal `uint64_to_int64` (baked into the
  already-compiled binary) still does the slow counting loop whenever
  IT parses a large literal from ITS OWN input — this is exactly why
  `Edsger_v1/src/modular/Edsger/Codegen.ptl`'s own float-constant
  helpers (`mask32()`/`two_pow_32()`/`mask52()`/`inf_exp_bits()`/
  `bias1023_shl52()`/`pos_inf_bits()`/`qnan_bits()`/`ln2_bits()`/
  `inv_ln2_bits()`) still have to build large constants from small-
  literal bit shifts rather than writing them directly — confirmed by
  trying the obvious "replace codegen_selfhost with Edsger v0's own
  (now-fixed, dynamic-memory) `codegen` binary" swap, which segfaults
  outright on Edsger v1's real source (raising the stack limit doesn't
  help) — a separate, real bug of its own, not attempted further here.
  **This part of the workaround stays, correctly, as documented,
  reusable technical debt** — it isn't the bug this fix closes, it's a
  downstream consequence of a DIFFERENT binary's own copy of it that
  isn't practical to chase down today.
- **Compiled by an Edsger-generation tool (not Hoare) → no excuse,
  fixed.** This is the actual, real bug: `Edsger_v0/src/modular/Edsger/
  {Sema,Parser}.ptl` and `Edsger_v1/src/modular/Edsger/{Sema,Parser}.ptl`
  — the REAL, ACTIVE, currently-shipping compiler sources for BOTH
  generations — are compiled by `codegen_selfhost` (an Edsger-
  generation tool, NOT Hoare directly), which has supported `as` since
  `v1.0.6`. Two more instances of the exact same anti-pattern were
  found this same pass, once the search widened past just the two
  original functions: `int32_of_int_val` (`Sema.ptl`, both generations)
  and `byte_to_uint64` (`Codegen.ptl`, both generations, a `uint8 ->
  uint64` widening loop bounded at 255 iterations — never actually a
  performance problem, but the same needless hack, complete with a
  comment claiming "v0 has no cast operator" that was simply wrong for
  a file Hoare never compiles). All four functions, in both `Edsger_v0/
  src/modular/` and `Edsger_v1/src/modular/`, are now one-line `as`
  casts. Verified against the REAL, released binary of each generation,
  not just the fixture suite: `postulate-edsger-release` (Edsger v0)
  went from 15+ seconds (`timeout` killing it) to 26ms on the exact
  same `mut x : uint64 := 5000000000;` program; `codegen_cases` passes
  for both generations; `uint64::MAX`/`int64::MAX` literals compile
  correctly in milliseconds; every `**`/`_/`/based-form/rune smoke test
  from this session's own earlier work still passes unchanged.

This was the SAME root cause silently affecting the `**`/`_/`
implementation work above during its own development (large compile-
time constants like `mask52()`/`ln2`'s own bit pattern couldn't be
converted through these functions either — worked around there by
avoiding the conversion entirely, not yet knowing at the time that the
conversion itself was the actual, fixable bug in the files that
COULD be fixed).

### Root-caused and fixed: `DynNodePool`'s own pointer-invalidation segfault (2026-08-31)

Direct follow-up to the "replace codegen_selfhost with Edsger v0's own
binary" segfault noted (not chased down) in the entry just above — the
user explicitly asked for it to be found and fixed once it looked like
an independent bug, and separately asked for a full audit of every
`Dyn*` structure for the same class of issue before starting.

**Root cause, found via `gdb` (installed into the release image ad
hoc) against the actual crash, not guessed at**: `DynNodePool` grows
via `sys_mremap(..., 1)` (`MREMAP_MAYMOVE`) exactly like every other
`Dyn*` structure — but unlike every other one, its own access pattern
can't tolerate a relocating grow. `alloc_node` hands out a raw `*ASTNode`
for the CALLER to hold indefinitely (every tree link -- `first_child`/
`next_sibling`/`left`/`right`/`extra`/`symbol_ref`/`data_type` -- IS
exactly one of these, held for the rest of compilation), so the classic
"container reallocation invalidates existing pointers" bug applies
directly: `parse_func_block` (and every other block/list-building
function shaped like it) does `n := alloc_node(...)` once, then calls
`parse_decl_stmt`/`parse_stmt` repeatedly (each of which calls
`alloc_node` MANY more times for child nodes), then writes back through
the ORIGINAL `n` (`(*n).first_child := d;`) — if the pool needed to
grow (and relocate) anywhere in between, `n` is now a dangling pointer
into memory the kernel already unmapped or reused. Confirmed at the
instruction level: `gdb`'s crash-time disassembly caught `mov
%rcx,0x20(%rax)` (exactly `(*n).first_child := d`, offset `0x20` being
`ASTNode.first_child`'s own field offset) with `%rax` holding a
plausible-looking but already-invalid address. Small/simple inputs
(Edsger v0's own, smaller real source) never cross a chunk boundary
mid-construction and never observed this; Edsger v1's own real,
larger modular source (grown further still by this session's own
`**`/`_/`/based-form/rune work) reliably does.

**Audit of every other `Dyn*` structure, as explicitly requested,
before writing a single line of the fix** (`DynBytes`, `DynSymbols`,
`DynBindings`, `DynTokens` — all four also grow via relocating
`sys_mremap`): none of them are vulnerable, and the reason is the same
one line, confirmed by grep, for each — no `*Symbol`/`*LocalBinding`
local variable exists anywhere in either generation's modular source,
and every `DynBytes`-backed buffer (`append_byte`/`append_str`/
`append_slice`/`append_uint`, the output-IR buffer included) always
`ensure`s THEN indexes through a freshly-read `(*buf).ptr[i]` in the
same call, never through a pointer a caller cached earlier. `DynTokens`
is read the same way (`cur_kind`/`cur_tok` index `(*p).toks.kind[(*p).
tok_idx]` fresh every time). `DynNodePool` is architecturally different
from all four: its entire PURPOSE is handing out a stable address for
long-term retention (that's what a parse tree's own links are), so it's
the one structure where "read through a fresh index every time" was
never actually possible in the first place.

**Fix, per the user's own explicit choice between the two options
raised** (reserve-and-commit virtual memory vs. segmented/chunked, non-
relocating storage) — chunked: `DynNodePool` is now a linked list of
`NodeChunk`s (`{ ptr: *ASTNode; next: *NodeChunk; }`), each its own
`sys_mmap` call, created once and NEVER resized or moved again; growing
links a brand new chunk onto the tail instead of growing the existing
one (`dynnodepool_alloc`, replacing the old `dynnodepool_ensure` +
manual indexing `alloc_node` used to do directly). Every `*ASTNode` ever
handed out now points into a chunk that exists, unmoved, for the rest
of the process's life — the exact property the old design never had.
Applied identically to both `Edsger_v0/src/modular/Edsger/Parser.ptl`
and `Edsger_v1/src/modular/Edsger/Parser.ptl` (plus each generation's
own `main.ptl`, which no longer needs the retired `node_count` field —
chunk/allocation bookkeeping now lives entirely inside `DynNodePool`
itself). Verified: `codegen_cases` passes for both generations; every
`**`/`_/`/based-form/rune/large-literal smoke test from this session's
own earlier work still passes unchanged; and, most directly, the
`Edsger_v0/build/codegen`-compiles-`Edsger_v1`'s-real-source
reproduction that used to segfault now fails with an ordinary,
non-crashing `sema error` instead (the literal-anchoring gap fixed
immediately below).

**Raised, not yet scheduled**: the user's own observation that this bug
is a concrete illustration of exactly why `v1.3.n`'s planned heap-
memory-safety work matters, plus a specific idea worth remembering when
that design round actually happens -- consider letting a pointer be
explicitly INVALIDATED (not just freed), so a stale reference like the
one this bug produced could be caught by the compiler's own ownership
checking rather than relying on the underlying storage never moving.
Not designed here; `own *T`'s own linear-consumption model (`v1.3.5`,
above) is the natural place to weigh it against.

### Root-caused and fixed: `-N` (unary minus on a literal) not anchoring to a wider expected type (2026-08-31)

**Why this was missed for so long, the user's own explicit question**:
every occurrence of it THIS SESSION was treated as a quirk to route
around (`mut neg_exp : int64 := -1;` failing, worked around by writing
`0` then `neg_exp := neg_exp - 1;` instead; the `**`-negative-exponent
smoke tests built the same way) rather than recognized as a real,
independent Sema gap worth fixing on its own -- and it stayed invisible
to Edsger's own self-compile for an unrelated reason: `codegen_
selfhost`'s own (Hoare-lineage, structurally different) Sema doesn't
have the restriction at all, so `Sema.ptl`'s own `mut matched_rule :
int64 := -1;` (`resolve_path`) compiles fine THROUGH that tool even
though the exact same line fails against either generation's own freshly-
built, CURRENT compiler -- the divergence the `DynNodePool` entry just
above stumbled into and originally misread as a v0-vs-v1 difference.

**Root cause**: `UNARY_EXPR` (kind 147) was never itself one of the
"literal-shaped" kinds `is_literal_kind` recognizes (`INT_LIT`, `FLOAT_
LIT`, etc.) -- every anchoring call site (`check_expected`, covering
decl-init/assignment/return/if-while/call-args in one place; `BINARY_
EXPR`'s own left/right anchoring; array broadcast-init) gates on
exactly that check to decide "does this operand get `decorate_literal_
with_expected`'s context-aware treatment, or plain `decorate_expr`'s
context-free one" -- so `-1` always took the context-free path: the
inner `1` defaulted to `int32` (its ordinary, unanchored default) and
was negated as `int32` BEFORE ever being compared against whatever
wider type the surrounding context expected, guaranteeing a mismatch
for any target wider than `int32`.

**Fix**: a new `is_literal_expr(e)` (alongside the existing `is_literal_
kind(k)`, which only ever took a bare kind number and so couldn't
inspect a `UNARY_EXPR`'s own operand) recognizes `-N` too, and `decorate_
literal_with_expected` gained a matching `k == 147` branch: decorate
the INNER literal against the SAME expected type first (so `-1`
targeting `int64` anchors the `1` to `int64` before negating, not to
`int32`), then re-apply the exact signed-operand-only restriction
`decorate_expr`'s own ordinary (non-anchored) unary `-` already
enforces elsewhere in the same file -- an anchored `-1` targeting an
UNSIGNED expected type is still correctly a type error (kind 13,
`mut x : uint64 := -1;` stays rejected), the same way negating an
already-`uint64`-typed value already was; anchoring must never become a
backdoor around that established rule. Every `is_literal_kind` call
site that had a real `*ASTNode` available (not just a bare kind number)
was switched to `is_literal_expr` -- **except one, deliberately**:
`Edsger_v1`'s own `CAST_EXPR` operand-anchoring site (added earlier
this same session for `5000000000 as int64`/string-vs-rune
disambiguation) keeps the narrower `is_literal_kind` on purpose, since
`-1 as uint64` (the "all bits set"/`SIZE_MAX` idiom, same spelling as
C's `(unsigned)-1`) is an already-established, already-working pattern
that an EXPLICIT cast should keep allowing -- the literal `1` gets its
ordinary signed `int32` default, negation succeeds (the "unsigned
operand" restriction only ever applies to an ALREADY-unsigned-typed
value), and the cast's own widen-then-reinterpret (`sext`) is what
actually produces the huge unsigned result; anchoring the `1` straight
to `uint64` before negating would turn that same expression into a
hard error instead. `Edsger_v0` has no such site to begin with (its own
`CAST_EXPR` decoration never grew v1.1.n's literal-anchoring extension,
so `(-y) as uint64`-shaped casts there already always went through
plain `decorate_expr`, unaffected either way).

Applied to both generations' `Sema.ptl` (`Edsger_v0` needed three call
sites updated -- `check_expected` and `BINARY_EXPR`'s own left/right,
it has no `CAST_EXPR`-literal-anchoring or broadcast-init infrastructure
to begin with; `Edsger_v1` needed the same three plus broadcast-init,
with `CAST_EXPR` deliberately left alone as just explained). Verified:
`codegen_cases` passes for both; `mut x : int64 := -1;`,  an anchored
`-N` inside a comparison against an already-typed value, and array
broadcast-init all now work in both generations; `mut x : uint64 :=
-1;` is still correctly rejected (kind 13) in both; `-1 as uint64`
still correctly computes `uint64::MAX` in `Edsger_v1` (the deliberately-
preserved idiom); every other smoke test and fixture from this
session's own earlier work is unaffected.

**Flagged for the user's own explicit "review very thoroughly during
testing" request**: `as`-cast sign/width reinterpretation generally
(`-1 as uint64` above being the concrete trigger) — once real, dedicated
testing work happens (see [[project-postulate-testing-strategy]]), this
whole family of conversions deserves deliberately adversarial coverage,
not just the one idiom this entry happened to touch.

### Implemented: `main(argv, argc)`, the two-parameter form (`v1.1.4`, 2026-08-31)

`Edsger_v1` only, per its own place in the roadmap (`v0` predates
`v1.1.n` entirely, so this was never in its scope) — closes the last
still-open `v1.1.n` language-surface gap this session's own earlier
status check found.

**Sema**: `main` (found the same name-text-only way `gen_start` already
does, unscoped by namespace — matching, not exceeding, what Codegen
itself enforces) must now take either zero parameters or exactly
`(**char, uint16)` (`is_named_main`/`main_params_valid`, new) — anything
else is a new err_kind (30). Param NAMES were never part of the
restriction (postulate_v1_language_reference.md SS6.3 only fixes the
two structural shapes), so `main(args: **char, count: uint16)` is
equally legal.

**A real, independent parsing collision found getting here**: `**char`
failed to parse at all before this fix — `parse_type` only ever
recognized a single `*` token (kind 81) as the start of a pointer type,
but the LEXER (this same session's own earlier `**` operator work,
`v1.1.3`) already merges two adjacent `*` characters into ONE token
(kind 165, the exponentiation operator) well before the parser ever
sees them. `parse_type` gained a matching `165` branch that un-merges
it back into two `TYPE_POINTER` levels — deliberately scoped to just
the shape actually needed (`**` followed by an ordinary type), not a
full replication of the single-`*` branch's own extra cases (`*const
T`, the `*T[N]` array-of-pointer speculative lookahead) at the second
level.

**Codegen — the real work, `gen_start`**: reading `argc`/`argv` off the
process's own real initial stack needs the raw, kernel-provided `rsp`
at the EXACT moment `_start` gains control, before anything else has
touched it. Confirmed the hard way (`llc`'s own disassembly, byte for
byte) that an ordinary, non-`naked` `define void @_start() { ... }` had
`llc` insert a stray `pushq %rax` BEFORE an inline-asm `movq %rsp, $0`
placed as the IR's own first instruction — nothing marks `_start` as
special, so `llc` silently applied its own default stack-alignment
prologue regardless of source order, shifting `rsp` by 8 bytes before
the read ever ran. The `naked` function attribute suppresses this
entirely (confirmed empirically, then end to end: a real linked binary,
invoked with real command-line arguments both present and absent,
correctly printed its own `argv[0]`/each argument/the right `argc`
back out) — safe per the SysV ABI's own documented guarantee that the
kernel's initial `rsp` is already 16-byte aligned at process entry,
exactly what an ordinary `call` needs immediately before it, so a naked
`_start` calling `main` with zero intervening stack traffic needs no
alignment fixup of its own either. `_start` is now unconditionally
`naked` (harmless and slightly smaller for the zero-parameter form
too, not just a special case for the new one) — a real, deliberate
change to EVERY program's own emitted `_start`, not just ones using the
new form; all 9 `codegen_cases` goldens needed regenerating for exactly
this one line, nothing else. `main_params_valid` having already run in
Sema means `gen_start` itself never needs to re-check the shape --
`has_args := (*main_decl).first_child != null` is sufficient once that
invariant holds. Existing generic function codegen (`gen_function`/
`is_supported_value_type`) already handled `**char`/`uint16` as
ordinary parameter types with no changes at all — `is_supported_value_
type`'s own `TYPE_POINTER` case already recurses through arbitrary
pointer nesting.

Verified: `codegen_cases` (all 9, post-regeneration) passes; a real
compiled program using `main(argv: **char, argc: uint16)`, run with
three real arguments and separately with none, correctly reads both
back (`argc`/each `argv[i]` written to stdout, matching the real
invocation exactly); `main(x: int32)` and `main(argv: *char, argc:
uint16)` (single pointer, the one-off-shape mistake) are both correctly
rejected with the new message; every other smoke test and fixture from
this session's own earlier work (pow/root, based-form, rune,
`DynNodePool`, the negative-literal-anchoring fix) is unaffected.

**Follow-up found immediately after, same root cause, different parser
rule**: `**p`/`***p`/`****p` (multi-level pointer DEREFERENCE, an
expression, not a type) failed to parse too, for the exact same reason
`**char` did -- `parse_unary` only ever recognized single-character
prefix operators (`! - * &`, token kinds 79/80/81/82), with no case at
all for the merged `**` token (165). Fixed the same way: a new `k ==
165` branch in `parse_unary` un-merges it into two nested UNARY_EXPR
dereferences, recursing through `parse_unary` again for whatever
follows (so `***p`/`****p` resolve for free, one more `*` or `**`
token respectively, exactly like the type-side fix already does for
`***T`/`****T`). No ambiguity with the INFIX `**` (exponentiation)
operator -- that one is only ever reachable from `parse_power`, after
an operand already exists, never as the first token of a fresh unary
expression. Verified: a real program declaring `*int32` through
`****int32` locals and dereferencing all four levels back
(`****p4`) computes the correct value; `codegen_cases` and every
other smoke test from this session unaffected.

**Testing priority flagged 2026-08-31, for [[project-postulate-testing-strategy]]**:
arbitrarily long `*`-chains (both in type position, `*`/`**`/`***`/...,
and in dereference-expression position) should be exercised well beyond
what these two fixes happened to check by hand (4 levels) once real
systematic testing work happens -- the lexer's own greedy `**`-as-one-
token merging means every EVEN pointer depth reads as a run of `**`
tokens and every ODD depth as `**`-tokens-plus-one-trailing-`*`, a
parity distinction neither fix's own hand-written smoke test isolated
on its own; a dedicated, deliberately deep (well beyond 4) regression
test belongs in the real suite, not just this session's throwaway
scratch file.

### Implemented: `opt` wired into the `edsger` CLI as a gcc-style `-O` switch (`v1.1.1`, 2026-08-31)

Before wiring it in, empirically checked the one risk this session had
reason to worry about: whether `opt -O1`/`-O2` could disturb the
`naked _start` + raw-`rsp`-read trick or the `asm sideeffect` syscall
wrappers (`main(argv, argc)`, immediately above, and every `extern
function` in `postulate_v1_language_reference.md` SS5.2). Ran
`smoke_main_argv.ptl`'s emitted IR through `opt -O1 -S` and `-O2 -S`
directly, then `llc`/`ld`/execute: the `naked` attribute and the
`_start` function body came through byte-for-byte unchanged at both
levels (`opt`'s own IR-level passes have nothing to reorder around a
`sideeffect`-marked asm call that's already the first instruction in
its block, and `naked` itself is a backend/codegen-level suppression
`opt` never touches), and the real argv/argc round-trip still printed
correctly. Confirmed safe to proceed.

Added a `-O0|-O1|-O2|-O3|-Os|-Oz` flag to both `Edsger_v0/edsger` and
`Edsger_v1/edsger` (identical scripts, patched identically), gcc-style,
defaulting to `-O1`. `opt "-$opt_level" -S` now runs between `codegen`'s
raw LLVM IR output and `llc`, for every level except `-O0` (which skips
`opt` entirely and feeds `codegen`'s output straight to `llc`, as
before). `--emit-llvm` now dumps the post-`opt` IR (so it reflects
whatever level was actually requested, `-O1` by default), not the raw
pre-optimization text. Verified all six levels (default, `-O0` through
`-O3`) round-trip correctly on `smoke_main_argv.ptl`, that `-O2
--emit-llvm` still shows the `naked` attribute intact, and that an
invalid level (`-O9`) is rejected by the existing unrecognized-option
path (exit 64) with no new failure mode introduced.

**Deliberately not touched by this change**: this only affects
`codegen`'s LLVM IR on its way to `llc` inside the `edsger` CLI wrapper
script -- it does NOT touch `Codegen.ptl`'s own emitted text, so the
`codegen_cases` fixtures (which diff that raw, pre-`opt` text) are
completely unaffected; no fixture regeneration needed, unlike the
`naked`-attribute change earlier this session. Also deliberately not
yet done: making the bootstrap self-build (`scripts/build.sh`, i.e. the
compiler compiling *itself*) use `-O2` by default -- the user's stated
intent is for Edsger to always self-build at `-O2` eventually, but
introduced in stages, with a proper version-controlled runtime-behavior
test suite (see below) landing first, before release.

**Real gap this surfaces**: `codegen_cases` only ever diffed Codegen's
own text output, never actual compiled-and-run behavior -- it was never
going to catch an `opt`-introduced miscompilation even in principle,
since `opt` sits downstream of everything that suite checks. Every
correctness check this session ran for the riskier changes (`main
(argv,argc)`, the pow/root rewrite, the pointer-depth fixes, and now
this) was an ad hoc, throwaway scratchpad smoke test -- compile, link,
run, check the exit code by hand -- never promoted into a tracked,
version-controlled suite. Turning `-O2` on by default for Edsger's own
self-build makes this gap load-bearing rather than theoretical, which
is exactly why the user wants a real runtime-behavior test suite in
place first, as its own pre-release step, rather than treated as an
afterthought here.

### Started: the first real black-box test suite, plus two real bugs found and fixed (2026-08-31)

The user's own explicit reasoning for starting this now rather than
later: Edsger's *language surface* is close to done (only polymorphism,
`v1.2.n`, and verification, `v1.3.n`, remain as language-level
additions), so this is close to the last moment a test suite built
against "the whole surface" won't immediately go stale. Deliberately
scoped as **black-box** testing (compile a whole `.ptl` program with
the real `edsger` CLI, check the observable outcome -- exit code,
stdout, or the diagnostic text on a deliberate error) rather than the
existing `codegen_cases`/`sema_cases`/etc. fixtures' white-box, single-
compiler-stage text-diff style. New home: `Edsger_v1/tests/
blackbox_cases/` (no runner script yet -- the user's own explicit
choice this round was to keep writing more cases first, not to wire up
automation before there's enough here worth automating).

**`kitchen_sink_v1_1.ptl`**: one program, no attempt at real-world
sense, structured as 18 independent self-check functions (each
returning `bool`) covering every confirmed-implemented `v1.1.n` surface
feature at once -- control flow (`if`/`elseif`/`else`, `while`,
`break`/`continue`), `:+ :- :* :/`/`++`/`--`, `ref` parameters, operator
overloading, array broadcast-init/assign, pointer arithmetic, arbitrary-
depth pointer types/deref (the exact testing priority flagged earlier
this session), struct layout (natural alignment), `rune`/multi-byte
char literals/`char[N]`/`rune[N]` strings, function types, `->` deref-
sugar vs. auto-deref `.`, nested struct literals, casts, based-form
literals, negative-literal anchoring (the other flagged priority), the
fractional-exponent `**`/`_/` rewrite, the documented ordered-`fcmp`
NaN quirk, and the syscall whitelist (`write`/`mmap`/`mremap`/`munmap`/
`gettid`/`openat`/`close`). `main` prints one status character per
check (`'1'`/`'0'`) plus a final pass/fail exit code, rather than
packing results into the exit code itself -- Linux truncates exit codes
to 8 bits, which would have silently collided past the 8th check.
Passes all 18 checks at every optimization level (`-O0` through
`-O3`), confirming the `-O`-switch work above didn't regress anything
real.

**A real language rule this file's own construction ran into, twice,
independently, at two different scopes** -- not a bug, but confusing
enough that it deserves its own note, and easy to reproduce by
instinct if unaware of it: `func_block ::= "{" decl* stmt* "}"`
(`Parser.ptl`'s own comment calls this "grammar-enforced") is stricter
than it first looks. It is not just "all decls before any statement in
the same block" -- **only a function's own outermost block can declare
new `mut`/`const` locals at all.** A nested `if`/`while` body parses
via the separate, decl-less `parse_block` (a bare `stmt*` loop -- there
is no branch in `parse_stmt` for the `mut`/`const` keywords at all,
only `parse_func_block`'s own decl-then-fallthrough logic has one), so
a `mut` declared inside a nested block is a parse error regardless of
its position relative to other statements there; it has to be hoisted
to the enclosing function's own top-level decl section (declared
without an initializer if the real value depends on something computed
later) and then assigned via a plain `:=` statement wherever it's
actually needed. First hit while writing `kitchen_sink_v1_1.ptl` itself
(three functions needed restructuring); hit again, independently, while
fixing the `use`-alias bug below, in the compiler's own source.

**Empirical answer to "does the compiler find more than one error at
once, including different kinds together"** (the user's own explicit
question motivating this whole round) -- confirmed via dedicated probe
files, not just read off the source:
- **Multiple syntax errors, yes**: the parser's panic-mode recovery
  (`synchronize_stmt`/`synchronize_toplevel`) genuinely accumulates and
  reports every syntax error in a file, not just the first --
  `err_syntax_multiple.ptl` (three unrelated broken functions) reports
  all three (four diagnostic lines total, one function's malformed
  `if` produces two).
- **Multiple semantic errors, no**: `Sema.had_error` is a single
  boolean, checked at dozens of call sites throughout `Sema.ptl`
  (`while (... && !had_error)`, `if (had_error) { return; }`) --
  `err_semantic_multiple.ptl` (three independent, unrelated type
  errors) reports only the first and stops. This is real, deliberate,
  already-tracked debt, not new debt: `v1.1.12`'s own roadmap entry
  above already commits to fixing this specifically when Sema's symbol
  table gets rebuilt for the module-system overhaul. **Deliberately not
  patched piecemeal now** -- the user's own call, after weighing it:
  retrofitting accumulation onto the existing single-error short-
  circuit pattern would touch essentially every decoration function in
  the file, and doing it carefully (deciding what "keep going after an
  error" should even mean at each site, so a first failure doesn't
  cascade into a pile of spurious follow-on errors) is exactly the kind
  of thing that belongs in the planned rebuild, not a bolt-on here.
- **A lex error suppresses everything else, including unrelated later
  syntax errors**: `err_lex_then_parse.ptl` (an unterminated string in
  the first function, an unrelated broken expression in the second)
  reports only the lex error. `main.ptl`'s own file-loading loop
  aborts the moment `FileSet.had_error` is set (a lex error OR any
  parse error) before Sema ever runs -- but a lex error specifically
  also short-circuits the *parser's own* otherwise-multi-error-capable
  reporting for anything later in the same file, since lexing produces
  the whole token stream up front, before parsing starts at all.

**Bug found and fixed: `*const T` / a `const`-declared local were both
parsed but never actually enforced.** `TYPE_POINTER.is_mutable`
(`*const T`, `v1.1.11`) and `DECL_STMT.is_mutable` (`const` vs `mut`)
were both recorded correctly by the parser, but nothing in `Sema.ptl`
ever consulted either flag before allowing a write through an
assignment or `++`/`--` -- confirmed empirically (`err_const_pointer_
violation.ptl`: writing through a `*const int32` parameter compiled
clean and *ran*, returning the written value; a bare `const x: int32
:= 1; x := 99;` local reassignment did too). Fixed with a new `is_const
_lvalue` predicate (`Sema.ptl`, alongside the existing `is_lvalue_expr`
it complements): an `IDENT_EXPR` is const if its `symbol_ref` is a
`DECL_STMT` (never a `PARAM_DECL` -- that field is reused there to mean
"is a `ref` parameter", `v1.1.5`, so an ordinary by-value parameter
must stay freely reassignable) with `is_mutable == false`; a dereference
(`*p`, or the implicit one `->`/auto-deref `.` already builds) is const
if the pointer's own `TYPE_POINTER.is_mutable == false`; a `FIELD_EXPR`/
`INDEX_EXPR` recurses into its base when the base isn't itself a
pointer, so a `const`-declared struct's own field, or a `const`-
declared array's own element, is caught too. Wired into both
`ASSIGN_STMT` (kind 135, covering plain `:=` and the compound forms)
and `INCDEC_STMT` (kind 160); new `err_kind` 31, message "cannot assign
to a const-qualified target". Confirmed via the full `codegen_cases`
suite (unaffected) plus the two dedicated probe files (now correctly
rejected) and `kitchen_sink_v1_1.ptl` (still compiles clean, since it
never violates this).

**Second bug found and fixed, while adding the first real multi-file
namespace test**: the `::`-qualified single-symbol `use` form's `as`
alias was silently ignored. `use \Vendor\Math::Add as Plus;` compiled
fine but calling `Plus(...)` failed with "unknown identifier" -- only
the never-aliased-away original name `Add` ever worked. Root cause in
`symbol_individually_used` (`Sema.ptl`): the "does this import expose
the name being queried" check compared the query unconditionally
against `child.tok` (the import's own ORIGIN name), never against
`child.right` (the alias `PATH_SEGMENT`, when one was given) --
exactly the check its sibling branch (the plain-form `int_val == 0`
case, three lines down) already gets right. Fixed to check `child.right`
first when non-null, falling back to `child.tok` only when there's no
alias -- mirroring the existing plain-form logic exactly. New passing
fixture: `Edsger_v1/tests/blackbox_cases/ns_multi/` (`Vendor/Math.ptl`
declaring `\Vendor\Math`, `main.ptl` using both `use \Vendor\Math::Add
as Plus;` and the unaliased `use \Vendor\Math::Sub;`, confirming
namespace-path-to-`.ptl`-file default resolution and aliasing both work
together). Also confirms, empirically, that a `use`'s namespace path by
itself maps directly to `<path>.ptl` (`\Vendor\Math` -> `Vendor/
Math.ptl`) under the CURRENT resolver -- writing the symbol as a
further backslash segment instead of `::` (`\Vendor\Math\Add`, the
form `parser_cases/parse_test_02_use_forms.ptl`'s own stale fixture
still uses) resolves it as ANOTHER namespace segment instead
(`Vendor/Math/Add.ptl`) and fails to open -- a good concrete example of
why the exploration behind this round's testing work had to distrust
that fixture's own syntax rather than copy it directly (documented in
this session's own investigation, not guessed).

**14 negative (deliberately-broken) probe files**, one per distinct
diagnosed condition, each confirmed to produce exactly the expected
`err_kind`/message and a non-zero exit: `err_lexical` (unterminated
string), `err_syntax_multiple` (three unrelated broken functions),
`err_semantic_single`/`err_semantic_multiple` (the stop-at-first proof
above), `err_lex_then_parse` (the lex-suppresses-parse-too proof
above), `err_const_pointer_violation` (now correctly rejected, was the
first bug above), `err_dup_decl`, `err_ref_temporary` (a `ref` argument
that isn't a real lvalue), `err_array_lit_count`, `err_break_outside_
loop`, `err_struct_dup_field`, `err_struct_missing_field`, `err_arg_
count`, `err_not_callable`.

**Explicitly not yet done, by the user's own choice this round**: a
runner script to make this suite re-runnable/CI-shaped (deferred until
there's more coverage worth automating); more positive coverage
(multi-file `@shadow`, generics -- not applicable yet, `v1.2.n` -- and
deeper adversarial variants of the two testing priorities flagged
earlier this session). **The Sema single-error limitation, immediately
below, was NOT left deferred** -- the user asked for it directly,
right after seeing this section's own findings, once the goal (an IDE
pointing at every broken part of a file, not just the first) was named
explicitly.

### Implemented: Sema multi-error accumulation, for IDE-style diagnostics (2026-08-31)

**The ask, verbatim in spirit**: prepare the compiler to catch more
than one semantic error at once, with the end goal of an IDE being able
to point at every broken part of a program, not just the first.
Immediately follows the black-box testing round above, which is what
surfaced the gap concretely (`err_semantic_multiple.ptl`) and is also
what verifies the fix.

**Design chosen, and why the more thorough alternative was rejected**:
`Sema.had_error` is a single boolean, checked at dozens of sites
throughout `Sema.ptl` (`while (... && !had_error)`, `if (had_error) {
return; }`) as a "stop drilling into what I'm looking at right now"
signal. The maximally thorough fix -- true statement-by-statement
recovery inside a single function body, the way the Parser's own panic-
mode synchronization resyncs after a syntax error -- would need a real
"safe resync point" concept for Sema (skip to the next statement, but
explicitly poison/null any type information a later statement might
read back from the broken one, so it fails cleanly instead of
dereferencing garbage) that doesn't exist yet and isn't cheap to build
correctly. **Chosen instead**: keep every existing internal short-
circuit exactly as it was (still fully trusted, since it already
proven correct all session) for "stop analyzing THIS ONE top-level
declaration once something in it is broken" -- but make the OUTER
driver loops that iterate INDEPENDENT top-level declarations (every
function/operator in `decorate_program`, every `struct`/`function`/
`extern`/`operator` in `declare_program`, every struct in
`compute_all_struct_sizes`, every FILE in `main.ptl`'s own per-file
loops) "rearm" `had_error` back to `false` after each one, rather than
stopping the moment it's ever set. Since each of those units starts
completely fresh (a new `Scope`, no shared local state with its
siblings), this is safe by construction -- there is no path for a
poisoned reference from one broken function to reach a different,
unrelated function's own decoration.

**What this gets, concretely**: an error in one function no longer
blocks type-checking every OTHER function, struct, or operator in the
same file, OR in any other file in the same build (`use`-linked files
are decorated in their own per-file pass too). What it does NOT (yet)
get: multiple errors from WITHIN the same function body -- a broken
statement still stops that one function's own decoration where it
always did; this is the piece intentionally left for whenever `v1.1.12`
actually rebuilds Sema's symbol table and can build the resync-point
machinery properly, not bolted on here. Still a large, real
improvement for the IDE-diagnostics goal: most real-world edits touch
one function/struct at a time, and this makes every function/struct
*other* than the one being actively edited fully checkable.

**Mechanism**: a new `SemaError` struct (`Sema.ptl`, right beside the
pre-existing `CastWarning`, which already established the "collect an
array, print it all at the end" pattern for warnings) capturing the
exact same fields the old single-slot `err_node`/`err_file_idx`/
`err_kind`/`err_expected_type`/`err_expected_file` quintet already
carried. `Sema` gains `errors : *(SemaError[64])` / `error_count`
(same 64-cap style as the Parser's own panic-mode limit and
`CastWarning`'s own array). `set_error`/`set_expected_mismatch` (the
two functions every error report in the whole file already funneled
through, or was refactored to funnel through -- `declare_one`/
`declare_operator`/`compute_struct_size`/`field_type_size`'s four
inline error-setting blocks were each replaced with a plain call to
`set_error`, a nice simplification alongside the fix) now APPEND to
this array in addition to (not instead of) setting the old single-slot
fields, which every existing internal check keeps reading exactly as
before.

`main.ptl`'s own error-reporting code used to be two separate,
sequential `if (sema.had_error) { ...format one message off the
single-slot fields...; sys_exit(1); }` blocks (one for the declare
+struct-size phase's own kinds 1/2/3, a second, much larger one for the
decoration phase's kinds 3 through 31) -- merged into one combined
`while (ei < sema.error_count) { cur := (*sema.errors)[ei]; ...the same
formatting chain, reading off `cur` instead of the single-slot fields,
now also covering kinds 1/2 that the second block didn't...;
write_all_small(2, ...); ei := ei + 1; }`, with the `sys_exit(1)` moved
to run once, after the loop, only `if (sema.error_count > 0)`. The
per-file driver loops (`declare_program`'s file loop, `decorate_
program`'s file loop, both in `main.ptl`) dropped their own `&&
!sema.had_error` guards entirely -- they never needed to stop early
once `had_error` no longer stays stuck true past one bad declaration.

**Verified**: full `codegen_cases` regression (unaffected -- purely
additive plus internal loop-guard changes, no change to what compiles
cleanly), `kitchen_sink_v1_1.ptl` (still 18/18 at every `-O` level),
every existing negative probe (single-error cases still report exactly
one error, `err_dup_decl`/`err_const_pointer_violation`/etc. all
unaffected). `err_semantic_multiple.ptl` (three unrelated type errors,
three different functions) now reports **all three**, confirming the
fix directly against the exact file that originally proved the gap. A
new fixture, `err_multi_file/` (`main.ptl` with its own type error,
`use \Helper::broken;` pulling in `Helper.ptl` with an unrelated type
error of its own), confirms accumulation crosses FILE boundaries too,
not just declaration boundaries within one file -- both errors (one
per file) print together in a single run.

### A self-hosting dry run against `codegen.ptl` itself (2026-08-28)

**Not `v1.1.14` itself, and doesn't close it** — recorded here as a
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
3. **Array broadcast-init (`v1.1.7`, above) is exactly as unimplemented
   as that row already says**, confirmed by `codegen.ptl`'s own source
   actually needing it: `mut seen_arr : bool[64] := false;` and a
   dozen-plus `uint8`/`int32`/`uint64[N] := 0;` locals (including
   `out_buf`'s own 8-MiB array) all failed the same way `v1.1.7`
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
   whenever `v1.1.7` itself is actually implemented, for real, as its
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

**What this does and doesn't mean for `v1.1.14`.** This dry run does
**not** close `v1.1.14` — that step needs Edsger to accept its own
*real* source (a genuine leading `namespace \Main;`, one real v1
program, no capacity workarounds) and produce a linked, running binary
from it that agrees with itself across two generations, exactly as that
row already describes. What it does establish: (a) once `v1.1.7` is
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
guarantee beyond the per-module, opt-out-able coverage `v1.3.3`
provides; a `string`/console-I/O/threading standard library
implementation (the *type-level* design for `string`/`rune`/
`rune_string` is decided, §6 below — building the actual library isn't
in this plan); struct field reflection; a general FFI; OOP-style
polymorphism/type classes; and any language-level data-race
protection. None of them are scheduled as a step in this plan.
Namespaces are **not** on this list anymore — they are core v1 (§6.2),
built as part of `v1.0.6` above, not a future language generation.
**Plain generic functions are also no longer on this list** — moved
into v1 scope, §6 below, monomorphized rather than deferred to Noam
alongside type classes/OOP.

## 6. Decided language-reference changes, queued for the next batch update

Reviewed 2026-08-29, from a list of proposed v1 additions/fixes the
user drafted in `temp/New-v1-language-reference.md`'s own "Javasolt
bővítések és javítások" section. Each item below is **decided**, but
deliberately **not yet applied** to `postulate_v1_language_reference.md`
— per the user's own instruction, these get introduced into the
reference together, in one batch, rather than one at a time as each is
decided — every item from the original review has now been through
this process, including the `use ... as` renaming question, resolved
below alongside a broader namespace-scoped-resolution fix it turned
out to depend on.

- **`decreases` becomes mandatory on every recursive function, not just
  `pure` ones** (§5.3/§7.2 currently only require it for `pure`
  recursive functions). Decided after reviewing the whole recursive-
  function correctness model against the Why3/Hoare-logic tradition
  the language already follows: termination should be as symmetric a
  requirement for recursion as it already is for `while` (§7.1 already
  mandates at least one `decreases` on every loop) — an ordinary
  recursive function getting a free pass on termination while every
  loop doesn't was the actual gap, not something to preserve. A
  companion idea (a separate `invariant`-like clause for functions,
  analogous to a loop invariant) was considered and explicitly
  **rejected** — Why3 and the broader tradition this language follows
  don't have a function-level invariant concept because a function's
  own `requires`/`ensures`, used inductively (assume the recursive
  call's `ensures` holds, justified by `decreases` giving a
  well-founded measure; prove the body then satisfies the same
  `ensures`) already *is* the complete recursive correctness proof
  obligation — adding a separate invariant would be redundant with
  `ensures` at best, and has no established formal role to fill
  otherwise, unlike the loop invariant's well-defined one.

One item from the same review turned out to need **no change at all**:
unary `-` on an unsigned integer operand is **already** a compile
error in the current v1 reference (§3.4's own unary-operators note,
"Unary `-` on an integer now requires a *signed* integer type") — a
v0→v1 tightening that already exists, not a new decision.

- **File discovery (§6.3) changes from "symbol name → filename" to
  "namespace path → directory, scanned for the symbol."** Currently a
  *fully-qualified symbol's own name* becomes the filename
  (`\Core\Math\calculate_norm` → `Core/Math/calculate_norm.ptl`) — every
  segment up to the last becomes a directory, the last becomes
  `<name>.ptl`. This effectively requires one file per symbol by
  default; a real "module with many functions" (the actual, common
  shape a namespace's worth of related code takes — the equivalent of
  one class in an OOP language, without Postulate v1 having classes)
  only worked today as a side effect of §6.2's flat/global visibility
  once *some* file gets read for *any* reason. **New rule:** the
  *entire* fully-qualified namespace path becomes a directory (no
  segment reserved as a filename), and the compiler scans every `.ptl`
  file directly inside that directory that declares exactly that
  namespace, looking for the requested symbol among them — filenames
  become free-form within a namespace's own directory. Two files in the
  same directory declaring the same namespace and the same symbol name
  is a real, clean compile error (duplicate declaration within one
  namespace) — a strictly better failure mode than today's cross-
  namespace flat-visibility collision. `@autoload` simplifies alongside
  this: a pattern now redirects a namespace prefix straight to a
  directory, with no more "fold the remaining segment into a filename"
  step needed afterward.
- **New `@shadow` directive — real, file-level symbol override,
  distinct from `@autoload`.** Motivating cases: (a) debugging one
  function out of a many-function module without editing the module's
  own file; (b) customizing one symbol from a `verified` third-party
  package **without modifying it** — sometimes not even possible, since
  a `verified` dependency may ship only its compiled `.pto` interface,
  no `.ptl` source at all (§6.2c). `@autoload` can't do this: it only
  says *where else* to look, it doesn't stop the *original* location
  from also being read (and, post the file-discovery change above,
  the original module file would still be scanned for the rest of its
  own symbols regardless) — so both definitions would exist and
  collide as a duplicate declaration. `@shadow` has different,
  override semantics: the shadowing definition wins outright, and the
  original definition of that one specific name is silently excluded
  from resolution, even though the file/module that would otherwise
  supply it still gets read normally for everything else it holds.
  Same pattern-matching syntax as `@autoload` (literal prefix,
  `:placeholder`, or an exact full name — see the `::` addendum below
  for how a pattern says which of these it is), same
  `verified`/`unverified` third parameter, and the same
  **legal-only-in-`\Main`** constraint, for the identical
  anti-library-poisoning reason `@autoload` already has one.
  ```postulate
  namespace \Main;
  @shadow("\Vendor\Utils::helper_function", "debug/overrides");
  ```
  **`@shadow` also supports shadowing a whole sub-namespace, not just
  one symbol** — a real, separately-confirmed-needed capability, not
  just the single-symbol case above:
  ```postulate
  @shadow("\Vendor\Utils\", "debug/overrides");   // every symbol under \Vendor\Utils
  ```
  **Shadowing one symbol doesn't affect the `verified` trust status of
  anything else in that namespace** — the rest of a `verified` package
  keeps loading as pre-trusted axioms, unaffected. **The shadow
  definition's own verification status defaults to `unverified`** (it's
  new, unreviewed code, even if it's replacing something that was
  `verified`) — **but it can be given an explicit `verified` flag**,
  the third argument, exactly like `@autoload`'s own, if the
  replacement has itself actually been separately verified:
  ```postulate
  @shadow("\Vendor\Utils::helper_function", "debug/overrides", verified);
  ```
- **Symbol resolution becomes genuinely namespace-scoped, closing a
  real gap in the current (empirically-verified, §6.2 of the v1.0
  reference) implementation: visibility is today "effectively global
  and flat" once any file is read, regardless of namespace** — `use
  ... as Alias` parses but doesn't actually scope anything, and two
  unrelated namespaces each declaring a symbol with the same bare name
  collide program-wide with no way to disambiguate. Motivated by (and
  reusing) the same directory-based file-discovery infrastructure
  above — since the compiler now already knows which namespace/
  directory supplied a given declaration, Sema builds a real,
  namespace-partitioned symbol table instead of one flat pool. A bare
  name resolves against whatever's actually in scope for the *current*
  file (its own namespace, plus whatever it `use`s); two different
  `use`d namespaces both supplying the same bare name in the *same*
  file is a real, reported ambiguity, not a silent, program-wide
  collision.
  - **Namespace-level `use` can be aliased with `as` too** — no new
    keyword, `as` already exists for individual-symbol imports:
    ```postulate
    use \STD\Physics as Phy;
    ```
  - **New `::` separator**: `\` still joins namespace segments
    (`namespace \Core\Math;`, and any full namespace path inside a
    `use`/`@autoload`/`@shadow` declaration); `::` marks that
    everything after it is a **symbol name**, not a further namespace
    segment — used in two places:
    1. **A bare individual-symbol `use`**: `use \Core\Math::Vector;`
       imports the symbol `Vector` from `\Core\Math`, usable bare
       (unprefixed) in code — distinct from `use \Core\Math\Vector;`,
       which (if `\Core\Math\Vector` is itself a namespace, not a
       symbol) imports *that* namespace instead.
    2. **In-code access through an imported namespace prefix**, after a
       namespace-level `use` (aliased or not): `Math::Vector`,
       `Phy::Vector`. A namespace-level `use` (`use \Core\Math;` or
       `use \Core\Math as Alias;`) grants access **only** via this
       prefixed form — it does **not** also expose bare names, exactly
       mirroring Python's `import numpy` (only `numpy.array`) vs.
       `from numpy import array` (bare `array`) distinction; getting
       *both* forms for the same symbol just means writing both a
       namespace-level `use` and an individual `use ...::...` for it.
    A namespace-segment name and a symbol name **can** collide now (no
    restriction against it) — considered and explicitly **not**
    adopted, since `::` vs. `\` already disambiguates which is meant
    from the syntax alone, with no filesystem-dependent guessing
    needed; a same-named restriction would have been solving a problem
    `::` already solves more directly.
  - **Worked example** — a genuine ambiguity, and both ways to resolve
    it, assuming both `\Core\Math` and `\Physics` declare a `Vector`:
    ```postulate
    namespace \Main;
    use \Core\Math::Vector;
    use \Physics::Vector;      // ERROR: 'Vector' is ambiguous

    // Fix A -- rename one individually:
    use \Core\Math::Vector;
    use \Physics::Vector as PhysVector;

    // Fix B -- namespace-level import, prefixed access for both:
    use \Core\Math;
    use \Physics;
    // ... Math::Vector / Physics::Vector in code, never bare
    ```
- **Nested block comments.** `/* ... */` currently closes on the first
  `*/` seen, C-family style — a `/*` appearing inside an already-open
  comment has no special meaning. Changes to real nesting, matching
  OCaml/Standard ML/Rust/Swift/D (this language's own Hoare-logic/
  formal-verification lineage runs closer to the OCaml/SML side of that
  list than the C side): a single depth counter, incremented on every
  `/*`, decremented on every `*/`, the comment ends when it reaches
  `0`. **A `*/` that would take the counter negative is a lexer error**
  (an unmatched close with no open comment to end) rather than being
  silently reinterpreted as the ordinary `*`/`/` operator tokens —
  deliberately safe to make strict, since `*/` can never be valid
  syntax outside a comment anyway (`/` has no unary form, so a bare
  `*` immediately followed by `/` is never a legal token pair in real
  code). Solves the real, motivating pain point directly: safely
  commenting out a block that already contains a comment, without the
  comment silently ending early partway through.
- **`sizeof`/`lengthof`'s default type (no anchoring context) becomes
  `uintptr`, and their value is guaranteed to always fit in `uintptr`.**
  §2.7a already makes both untyped integer constants (§3.7) — they
  adapt to whatever context expects, same as a literal — so the
  original worry ("does the compiler pick something too small like
  `int8`?") doesn't apply in the normal, anchored case. Two real gaps
  remained: (1) with **no** anchoring context at all, an untyped
  integer constant falls back to `int`'s own default aliasing (the
  *narrower* width, per the existing `int`/`uint` convention) — too
  narrow to honestly guarantee against a `uintptr`-scale value, so the
  fallback becomes `uintptr` specifically, not bare `uint`; (2) the
  reference should say outright that `sizeof`/`lengthof` never exceeds
  what fits in `uintptr` — a real, principled bound (the target's own
  address-space width, the exact guarantee `uintptr` already exists to
  express), not an unstated assumption. **When anchored to a
  *specific*, narrower type by context and the actual value doesn't
  fit, this is a hard compile error, not a warning** — deliberately
  different severity from the anchored-literal-overflow item above:
  that one is a value the programmer typed by hand (occasionally
  arguably intentional, hence only a warning); `sizeof`/`lengthof`'s
  value is compiler-computed, known exactly at compile time, and a
  mismatch there has no legitimate use — silently truncating a
  computed struct size into an `int8`, say, is never something a
  program actually wants.
- **A real function type, but no anonymous/lambda functions at all in
  v1.** Considered both together, split deliberately: a function-typed
  value is only ever a reference to an already-existing, *named*
  top-level function — never an inline/anonymous function expression.
  Anonymous functions and true closures (capturing the enclosing
  scope) are excluded from v1 **entirely**, not deferred as a smaller
  "non-capturing lambda only" version — a captured-by-reference local
  outliving its own stack frame is exactly the memory-safety hazard the
  language's whole verification model exists to rule out, and reasoning
  about an unknown callback's behavior formally would need higher-order
  specifications, a real complexity jump beyond anything else in v1's
  contract system. This puts closures in the same "not v1, maybe never"
  bucket as type classes/OOP-style polymorphism (§11) — **not** the
  same bucket as plain generic functions, which moved *into* v1 scope
  after this item was decided; see the generics entry further below.
  **Syntax** (user-specified exactly):
  ```postulate
  mut x : (a : int, b : int) -> int := f;   // f an existing function
  ```
  Parameter *names* are written in the type, mirroring an ordinary
  function declaration's own style, even though only the types/arity/
  order are semantically load-bearing for compatibility — matches
  precedent like TypeScript/Swift's own function-type syntax.
  `->` (not `:`) separates the parameter list from the return type,
  deliberately — a real, acknowledged overlap with `->` also meaning
  implicit pointer dereference (this section, `p->field`) exists, kept
  intentionally: no real grammar ambiguity (a function type only
  appears in a *type* position, `p->field` only in an *expression*
  position — the same purely-positional disambiguation `*` already
  gets away with, meaning pointer-type/dereference/multiply depending
  on where it appears), and simpler than reusing `:` here would be. A
  function type is a real type — usable anywhere a type is (`mut`/
  `const` declarations, parameters, struct fields, another function's
  own return type), not only the `mut x : ... := f;` shape shown above.
  **A `pure` function-type variant exists too**: `pure (a : int) -> int`.
  Without it, a function-typed value could never be called from inside
  a contract clause at all (§7.2 only allows calling `pure`-marked
  functions there) — a `pure`-qualified function type lets a `pure`
  function accept a callback and still reference it from its own
  `requires`/`ensures`, exactly the same way it can already call any
  other named `pure` function.
- **A `rune`/`rune_string` design for UTF-8, entirely in `std` — not a
  core-language type, but two core-language mechanisms are needed to
  support it.** Goal: represent one full Unicode scalar value (`char`,
  §2.3, stays a single UTF-8 *byte*, not a code point — unchanged).
  Went through several iterations before landing here; earlier,
  rejected shapes are recorded too, since the reasoning matters as much
  as the result:
  - *Rejected: pointer + length into the original buffer.* Ties a
    `rune`'s own lifetime to whatever buffer it points into — the same
    dangling-reference hazard the closures decision above rules out for
    the same reason.
  - *Rejected: a decoded numeric code point (`uint32`-sized), as an
    alias of an integer type.* Smaller and pointer-free, but wrong on
    two counts: (a) an alias would let `rune` structurally interconvert
    with plain integers, when `char`/`uint8` already establish the
    opposite precedent for the exact same reason (same size, different
    *purpose*, deliberately not interchangeable) — `rune` must be a
    genuinely distinct nominal type, never an alias; (b) it throws away
    the original UTF-8 bytes, so *every* I/O operation (read a literal
    in, print one out) needs an explicit encode/decode round-trip even
    though the common case (store, copy, compare, print) never actually
    needs the numeric value at all.
  - **Decided: `rune` stores the original UTF-8 bytes themselves, by
    value, no pointer:**
    ```postulate
    struct rune {
        bytes : uint8[4];   // original UTF-8 bytes; unused trailing
                             // positions zero-filled
    }
    ```
    No separate length field — UTF-8's own leading-byte bit pattern
    (`0xxxxxxx`/`110xxxxx`/`1110xxxx`/`11110xxx` → 1/2/3/4 bytes)
    already determines the sequence length unambiguously, recoverable
    on demand (a `std` function, e.g. `rune_byte_length`) rather than
    stored redundantly. Zero-filling unused trailing bytes is safe
    against the one edge case worth checking: `bytes = [0,0,0,0]`
    unambiguously means U+0000 (NUL) — no other code point's leading
    byte is ever `0x00`, so there's no collision between "the NUL rune"
    and "padding zeros after a shorter real sequence." **4 bytes total**
    — same size as the rejected decoded-integer version, but now the
    *common* operations (construct from a literal, copy, compare with
    `==`, print) are all a plain byte copy/compare, needing no
    encode/decode step at all — UTF-8 has no aliasing (well-formed text
    has exactly one valid encoding per code point), so raw-byte
    equality is already correct rune equality. Only the *rare*
    operation — asking for the actual numeric code point (classification,
    case conversion) — needs an explicit `std` decode function, on
    demand, rather than paying for it universally.
  - **Two core-language mechanisms this still needs**, even though the
    `rune` type itself lives entirely in `std`:
    1. **A `char_literal` producing more than one byte becomes an
       untyped constant restricted to a new char/rune *family*** — not
       the general integer family. Today (§1.5) `'...'` is always fixed-
       type `char`; that stays true for exactly the 1-ASCII-byte case
       (no change, full backward compatibility). A genuinely multi-byte
       `'á'`-style literal instead becomes untyped-but-restricted:
       adapts only to `char` or `rune`, **never** to any integer type,
       mirroring exactly how the existing float family already can't
       adapt to an integer type or vice versa (§3.7) — a char/rune-
       shaped literal being usable as a plain number would be exactly
       the kind of accidental interconversion `char` vs `uint8` already
       exists to prevent.
    2. **String-literal decoding extends to `rune_string`** (an array
       of `rune`), reusing the same anchor mechanism already decided
       for native `string` support above: a string literal anchored
       toward a `rune`-array type is decoded *per code point*, not per
       byte, into a `rune[N]` array literal at compile time — the same
       mechanism, not a second one.
  - **Printing works with no encode step, by design** — a `rune`/
    `rune_string`'s own bytes already *are* well-formed UTF-8, so
    writing them straight to `sys_write` produces correct terminal
    output directly. This was the deciding argument for the whole
    bytes-by-value design over the earlier decoded-integer one:
    `const x : rune_string := "öüóőúéáű"; std:print_runes(x);` prints
    the accented text correctly with a plain byte-copy-and-write, no
    UTF-8 encode call anywhere in the path.
- **Compiler-enforced heap memory safety (leak, double-free, and
  use-after-free), via one new type qualifier plus automatic Why3
  instrumentation — significantly larger in scope than the rest of
  this section, likely its own dedicated future `v1.1.n` step rather
  than a small batched tweak.** Motivating context that changed the
  outcome mid-discussion: the planned kernel (SophonOS/Shagma) is
  **procedural**, compiled by Fothi/v2, not Noam/v3's future OOP —
  meaning this can't be deferred to "whenever Noam's ownership model
  gets designed" the way it first looked; it has to be solid already
  at the v1/procedural level, since that's the line the kernel actually
  sits on. Went through several rejected shapes before landing here —
  recorded because the reasoning, not just the result, matters:
  - *Rejected: full Rust-style ownership/borrow-checking type system.*
    A genuinely large type-system addition (comparable in scope to
    what generics/monomorphization below turned out to need) —
    explicitly ruled out by the user's own "minimize new syntax, no
    new compiler dependency" constraint.
  - *Rejected: pure convention — a `pure` `owns()`/`valid()` ghost
    predicate the programmer writes by hand into `requires`/`ensures`,
    checked the same way any other contract clause is.* Zero new
    syntax, reuses the existing Why3 pipeline entirely — but explicitly
    **rejected by the user**: "A konvenció nem elég... a nyelv maga
    kényszerítse ki" (convention isn't enough — the language itself
    must enforce it). Purely opt-in verification isn't enforcement: a
    program that never writes these clauses at all compiles and leaks/
    double-frees/use-after-frees freely.
  - **Decided: one new type qualifier, `own *T` (an *owning* pointer,
    vs. plain `*T`, now explicitly *non-owning/observing*), plus
    fully-automatic compiler-inserted verification — not
    programmer-written contracts.** The actual validity tracking is a
    **single, address-keyed ghost map** (`valid : address -> bool`)
    that the compiler's own Why3 translation (§7.8) maintains and
    checks automatically, the same way the existing §2.7b
    bounds-checking build already inserts checks automatically rather
    than requiring hand-written assertions:
    - Every allocating call (`sys_mmap`/`sys_mremap`'s own `std`
      wrapper) automatically sets `valid(address) := true` for the
      returned range, and its return type is `own *T` — a type-level
      fact, not a contract someone could forget to write.
    - The freeing wrapper (`sys_munmap`'s own `std` wrapper) takes
      `own *T` by value and automatically sets `valid(address) :=
      false` afterward.
    - **Every pointer dereference** (`*p`, `p.field`, `p[i]`) gets an
      automatically-inserted verification obligation, "`valid(p)`
      holds here" — never hand-written.
    - **Linear consumption of `own *T`, enforced by the compiler**: an
      `own *T` local/parameter must be consumed exactly once on every
      control-flow path before its scope ends — freed, returned as
      `own *T`, passed to a function expecting `own *T` (a move,
      transferring the obligation onward), or stored into an `own *T`-
      typed struct field (transferring it into a container — this is
      also what makes the model naturally forward-compatible with a
      future Noam constructor taking ownership into an object, without
      needing "the same variable" the user's own original framing of
      this problem worried about). A path that lets it go out of scope
      unconsumed, or overwrites it before it's consumed, is a compile
      error.
    - **A plain `*T` parameter is verified as truly non-owning
      automatically too**: the compiler checks it's never passed to the
      freeing wrapper and never stored somewhere that outlives the
      call — not something the receiving function has to additionally
      declare.
    - **Why this closes the use-after-free gap the leak/double-free-only
      version left open**: because `valid` is keyed by *address*, not
      by which specific pointer *value*/type refers to it, freeing the
      `own *T` original invalidates every plain `*T` observer derived
      from the same address too — a later dereference through the
      stale observer is caught by the same automatic per-dereference
      check as any other invalid access, with no separate mechanism
      needed for "observer outlived its owner."
  - **Explicitly flagged for precise definition when this is actually
    implemented, not resolved here**: exactly what "stored somewhere
    that outlives the call" means for the plain-`*T`-must-not-retain
    check above — e.g. the exact rule for a plain pointer written into
    a struct field, a global-scope table, or handed to another
    function that itself might retain it further. The user explicitly
    asked for this to be pinned down precisely at implementation time,
    not guessed at now.
  - **`own` can never apply to a stack address — free, by construction,
    not a special-cased check.** `&local` (address-of a local) is
    typed as plain `*T` by the `&` operator's own typing rule, full
    stop — only the allocating `std` wrapper's return type is ever
    `own *T`. `mut p : own *T := &local;` is an ordinary type mismatch,
    the same as any other wrong-type assignment; there is no separate
    "is this address secretly a stack address" runtime or semantic
    check to write.
  - **A plain, non-owning `*T` remains the right (and sufficient) type
    for general-purpose traversal/utility functions** — e.g. a
    `map`-style helper that walks `[p, p + len)` applying an operation
    to each element neither frees anything nor retains the pointer past
    the call, exactly the "observe, don't own" role plain `*T` already
    has. `*const T` (the pointer-to-const syntax above) tightens this
    further for a read-only pass. The ownership-tracking design doesn't
    get in the way of writing this kind of reusable helper — it was
    never meant to.
  - **The same "a plain `*T` must not be stored somewhere that outlives
    the call" check (above) also catches classic stack-pointer escape
    for free** — "return the address of a local" is the same underlying
    question ("does this pointer's value outlive what it's guaranteed
    valid for") as the heap use-after-free case, just with a stack
    address instead of a freed heap one. No separate mechanism needed;
    this was a deliberate design check during the discussion, not an
    afterthought bolted on.
- **Pointer-to-const syntax: `const` gains a second position in a
  pointer type, meaning "pointee is const" rather than "the pointer
  binding is const."** Today, `const p : *T` (§3.10) only makes the
  *pointer binding* immutable — `p := other;` is rejected, but `*p :=
  value;` (writing through it) is still allowed even so. There was
  previously no way to express "the pointee itself is read-only"
  (C's `const T*`) at all — arguably the more commonly useful of the
  two guarantees in practice, and entirely missing. Reuses the
  existing `const` keyword in a new position, no new keyword needed —
  `const` binds to whatever type follows it immediately, mirroring
  C's own `const`-placement convention adapted to this language's
  prefix `*T` pointer-type style:
  ```postulate
  const p : *T;         // unchanged: p itself can't be reseated
  mut p : *const T;      // new: p can be reseated, but can't write through it
  const p : *const T;    // both: neither reseatable nor writable-through
  ```
  Composes freely with `own` (an orthogonal axis — who's responsible
  for freeing vs. whether the pointee is writable): `own *const T` is
  a coherent, meaningful type ("I'll free this, but won't mutate it
  until then").
- **Adversarial test coverage, once Edsger's final v1 version exists**:
  deliberately try to break the memory-safety guarantees above with
  real, hostile fixtures — programs that leak allocated memory on
  purpose (never free/return/store an `own *T`, expecting a compile
  error) and programs that deliberately issue a use-after-free (free
  an `own *T`, then dereference a still-around plain `*T` observer of
  the same address, expecting the automatic `valid()` check to catch
  it). Not a "does it compile" smoke test — the actual goal is
  confirming the compiler **rejects** these programs as designed, the
  same "verified against real fixtures with checked exit codes/output"
  discipline this whole plan already holds every other step to (see
  "About this document," above), applied specifically to the
  ownership/validity feature once it exists.
- **Pointer-arithmetic `+` becomes non-commutative.** Currently (§2.5)
  both `p + n` and `n + p` are valid, and `p[i]` desugars to `*(p + i)`
  with no operand-order restriction — mirroring C, where `p[i]` and
  `i[p]` are both legal and mean the same thing. v1 instead requires
  the pointer to be the **first** operand: `p + n` valid, `n + p` a
  type error, `p[i]` stays valid, `i[p]`/`*(i + p)` (pointer as the
  *second* operand to `+`) becomes an error. Pure consistency gain — C
  itself has never had a real use for the commutative form.
- **Float literals gain a based form, reusing the existing integer
  `based_form` machinery** (§1.5: `based_form ::= digit+ "n"
  value_digit+`, bases 2/8/10/16). Extended grammar:
  `based_form ::= digit+ "n" value_digit+ ("." value_digit+)?
  (exponent)?`, where a fractional part makes the literal a float
  untyped constant (joins the existing float-family anchoring, §3.7)
  instead of an integer one — e.g. `2n101.001` = `5.125` (binary
  `101.001`), `16nf.0p3` = `15.0 * 16^3` = `61440.0`. **Every supported
  base gets an exponent, and the exponent's own multiplier is that same
  base** — not always base-10 or always base-2 the way e.g. C's hex
  floats fix the exponent to a power of 2 regardless of the mantissa's
  own hex digits; here `BASEn...eN`/`BASEn...pN` always means
  `mantissa * BASE^N`. **Exponent marker is `e`/`E` for every base
  except base 16, which uses `p`/`P` instead** — forced by the base-16
  digit alphabet itself including `e`/`f`, the same reason C's own hex
  floats use `p`. The exponent's own digits are always plain decimal,
  regardless of the literal's base (only the mantissa digits and the
  power's own base follow `BASE`).
- **A real, native `string` type**, not just something buildable out of
  `*char`/`char[N]` in the standard library. A string literal can be
  either a fixed-`N`-element `char` array or a real `string` value — an
  anchor (in the same family as the existing integer/(planned) float
  anchors) will be needed on the literal itself to say which one a
  given `"..."` should be.
- **`->` as implicit pointer dereference**, alongside the existing
  explicit `*p`/`(*p).field` forms — e.g. `p->field` instead of
  `(*p).field`. Exact desugaring and precedence still need pinning down
  when this is actually written into the reference (presumably
  postfix, same tier as `.`/`[]`/`()`, §3.1's own precedence table).
- **A compiler warning when an anchored numeric literal overflows its
  own anchor's type** — e.g. `300n8` (a base-anchored literal that
  can't fit in the width the anchor implies). Diagnostic-only, no
  change to what compiles or runs.
- **`elseif` becomes a real, direct n-way branch construct, not sugar
  for nested `if`/`else`.** §4.3 currently states explicitly that
  `elseif` "is pure sugar for that nesting" (desugars to nested
  `if`/`else` before or during semantic analysis). This reverses that:
  the AST/semantic representation keeps an `elseif` chain as one flat,
  n-branch construct, matching the general n-branch guarded-command
  shape §7's own branch-correctness rule already reasons about (the
  same section that currently justifies `elseif` as sugar precisely
  *because* the two shapes were considered equivalent for proof
  purposes) — chosen because a flat representation is what that
  proof rule wants to see directly, not reconstructed from nesting
  depth. `elseif` is not implemented in Edsger yet, so this changes a
  design decision only, no shipped behavior. A `switch`/`match`
  construct was considered and explicitly rejected — redundant once
  `elseif` chains are real, top-level branches.
- **`std` syscall-wrapper naming: swap which of `sys_exit`/
  `sys_exit_group` gets the shorter, more obvious `std` name.** A
  caller reaching for "exit" almost always means "end the whole
  process," not "end this one thread" — so the `std` wrapper around
  `sys_exit_group` should get the short name (`std:exit`), and the one
  around `sys_exit` the longer, more specific one (`std:exit_thread`),
  the reverse of naming them in raw-syscall order. `std` itself doesn't
  exist yet (§5 lists a standard library as deferred beyond this plan
  entirely) — recorded here so the naming is already decided whenever
  a `std` actually gets built.
- **Remove a misleading note from §5.3a (`ref` parameters).** The
  current text ("A `ref` parameter may not also be a composite type
  passed alongside §3.9's by-value copying rule...") reads as if `ref`
  is restricted away from struct/array types — it isn't (the language
  has no syntax to mark a parameter "by-value" in the first place, so
  a parameter being *both* `ref` and by-value-copied was never
  reachable to begin with; the note was trying to state that
  impossibility, confusingly). Delete it outright rather than
  reword it — it isn't adding information once the actual by-value
  default is understood.
- **A documented (non-enforced) naming convention**: `std` struct/
  function names start lowercase, user-defined ones start uppercase.
  Not a compiler-checked rule — just written down as guidance, since
  following it sidesteps name collisions between `std` and user code
  without the language needing to arbitrate them itself.
- **A custom `[]` (indexing) operator overload for structs — considered
  and explicitly left out of v1.** §5.4 currently allows overloading
  only §3.2–§3.4's binary operators (arithmetic/bitwise/comparison/
  logical) — `[]` isn't among them, and stays that way. This is real,
  future Noam (v3, OOP) scope, not v1 — no reference change needed now,
  this line exists only so the idea doesn't get silently lost.
- **Plain generic functions move into v1 scope — reversing the
  earlier "deferred to Noam alongside polymorphism" call (§11/§5).**
  Motivating need: writing the same function once per concrete type
  (`max_int32`, `max_int64`, `max_uint32`, ...) doesn't scale, and
  isn't what a language this deliberately explicit-and-typed should
  force. **Monomorphization, not runtime dispatch** — the only
  approach consistent with everything else this language already does
  ("no hidden runtime cost": erased contracts in a normal build,
  opt-in bounds-checking, `own`'s own compile-time-only tracking) —
  LLVM IR itself has no generic-function concept, so the alternative
  (a uniform boxed representation plus a vtable-style dispatch
  mechanism, Java-erasure style) would be the first genuinely
  runtime-cost-bearing abstraction in the whole language, rejected on
  that basis alone. Concretely: the compiler tracks every distinct set
  of concrete types a generic function is actually instantiated with,
  across the whole program, and Codegen emits one specialized LLVM
  function per instantiation — a real, new compiler phase (a
  monomorphization pass), not a small extension of anything existing.
  **Verification leans on Why3's own native support for polymorphic
  types/functions** — WhyML itself already has these, so a generic
  function's `requires`/`ensures` can plausibly be stated and checked
  *once*, generically, rather than re-verified per monomorphized
  instance — the exact split (verify generically vs. per-instance) is
  implementation detail for whenever this is actually designed in
  full, not resolved here.
  **Type classes (bounded/constrained generics — "T must support
  `==`", trait/interface-style bounds) are explicitly set aside for
  now, not decided either way** — a materially larger design layer on
  top of plain generics (bound declarations, constraint checking,
  coherence rules), and the user's own instruction is specific:
  **the final v1 language must explicitly settle whether it includes
  type classes, even if the answer ends up being no** — this is not
  something to leave silently unresolved the way, say, `[]`-operator-
  overloading is explicitly punted to Noam above. Whoever closes out
  v1's own design has to make this call one way or the other before
  v1 is considered finished, not just quietly ship without generics
  bounds and call it done.

## Beyond this plan

**Updated 2026-08-29** — `v1.2.n`/`v1.3.n`/`v1.4.n` are no longer
"beyond" this plan; they're §4's own second, third, and fourth
generations, planned in advance rather than left as an open-ended
placeholder. Once `v1.1.14` closes generation `1`'s own self-hosting
loop, Hoare (Stage 0) becomes historical for Edsger's own further
development — every later phase's own self-hosting checkpoint
(`v1.2.4`, `v1.3.7`, `v1.4.4`) recompiles Edsger with Edsger itself,
never Hoare again.

What's genuinely still *beyond* this plan: whatever Edsger work comes
after `v1.4.4` closes this plan's own four planned generations —
`v1.5.n` and onward, still targeting v1, numbered exactly as this
plan's own "Versioning" section describes, scope not yet decided.
Whatever eventually accumulates toward a genuinely new *language*
generation (reference §11's remaining deferred items, and type
classes if `v1.2.n` ultimately says yes to them) becomes `v2`, with its
own reference document and its own version of this plan (`v2.0.n`)
once that design work happens — not a continuation of the numbers
above, and not `v1.1`–`v1.4` (already spoken for by this plan's own
four generations, above).
