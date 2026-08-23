# Postulate Stage 1 bootstrap plan — from proof of concept to Edsger

## About this document

This is the implementation roadmap for turning the Stage 1 proof of
concept (lexer + parser + scalar-only codegen, `Stage1/src/*.ptl`,
compiled by Hoare) into a real, modular, self-hosted, optimizing
compiler for the [v1 language](postulate_v1_language_reference.md). It
answers a question the language reference itself deliberately doesn't:
not *what* v1 is, but in what *order* to build it, and why that order.

**Versioning.** Every step below is a version `v1.0.n`:

- The first `1` names the **stage** — Stage 1, the self-hosted
  successor to Hoare (Stage 0) — not a language-feature count.
- The `0` names the **language generation** — this is Stage 1's first
  target language, the one specified in `postulate_v1_language_
  reference.md`. A later, larger language change would be `v1.1.n`, a
  new document, not a renumbering of this one (see "Beyond this plan"
  at the end).
- `n` is the step number in this plan, incrementing by one per shipped,
  verified increment. `n` is a build order, not a language-reference
  section number — steps are grouped by dependency and risk, not by
  the order §1–§11 happen to appear in the reference manual.

**Naming.** The lexer/parser/codegen trio already built this session is
a **proof of concept only** and stays unnamed — it exists to prove
Hoare can bootstrap *something*, not to be anyone's long-term Stage 1
compiler. §3 below marks the exact point where it gets rewritten into a
real, modular compiler; from that point on, the compiler is named
**Edsger** (Stage 0's `Hoare` honors C.A.R. Hoare; Stage 1's `Edsger`
honors Edsger W. Dijkstra — the same relational/predicate-transformer
tradition §7 of the v1 reference draws its verification vocabulary
from). Every version from that rewrite onward is "Edsger `v1.0.n`."

**Verification discipline, unchanged from this session's work**: every
step below ships only once assembled/compiled, linked, and actually
**run** against real fixtures with checked exit codes/output — not just
"it parses" or "it compiles." Steps that touch the compiler's own
source additionally get a full regression pass across everything the
previous step already verified, exactly as this session's codegen work
did.

---

## 1. Why modularity comes first

The proof of concept is a single self-contained `.ptl` file per phase
(`lexer.ptl`, `parser.ptl`, `codegen.ptl`), each duplicating whatever it
needs from earlier phases — v0 has no `#include`, so there was no other
option (`Stage1/README.md`'s "why everything here looks the way it
does" explains this in full). That duplication is fine for three
~4000-line files; it stops being fine the moment the compiler grows to
cover all of v1 — contracts alone (§7 of the reference) are a
substantial, mostly self-contained subsystem that has no business being
copy-pasted into three places.

`#include` (§6.2) is also, conveniently, almost entirely **independent**
of the rest of v1: it's a preprocessing-time textual splice — path
resolution, recursive substitution, include-once, cycle detection — with
no interaction with the type system, the checker, or codegen at all. It
does not need `char`, floats, pointer arithmetic, `ref`, contracts, or
anything else in the reference to be useful; the *only* thing it needs
is a working lexer/parser, which the proof of concept already is. That
makes it the cheapest possible increment with the largest structural
payoff, which is why it is step one, not buried somewhere in the
middle once "enough of the language" exists to bother.

## 2. Why the backend changes before the rewrite

Three more things land before the architectural rewrite (§3), all
pulled forward from what the language reference's §11 originally
deferred, and all bundled together deliberately because they share one
underlying mechanism:

- **True separate compilation** (reference §11 item 2 — previously
  deferred beyond v1, now brought forward): independently compiled,
  cached, linkable units, instead of `#include` always re-splicing and
  re-compiling full source text on every build.
- **Real optimization**, using an existing, mature tool rather than a
  hand-written one.
- **Composite (struct/array) values across function calls, in Stage 1's
  own codegen** — v0 parity, not a new v1 feature. Hoare (Stage 0) has
  fully supported struct/array parameters and return values since early
  in its own development; the proof-of-concept Stage 1 codegen built
  this session deliberately left this out (`Stage1/README.md`'s scope
  note) to keep the first working slice small.

**The mechanism all three ride on: Stage 1's codegen stops emitting x86
NASM text directly and emits LLVM IR instead.** This is not a new
direction — it's the one already named as the project's intended path
(`Stage 0 asm → Stage 1 LLVM IR`) — just sequenced explicitly now. Four
consequences follow from that one change, which is why they're grouped
here as one arc rather than a handful of unrelated features:

1. **Optimization stops being something we'd have to build.** There is
   no mature, widely-used tool that takes already-generated x86 assembly
   *text* and applies real optimizations (constant folding, dead-code
   elimination, register allocation, instruction scheduling) as a
   standalone pass — NASM's own `-Ox` only optimizes instruction
   *encoding size*, not semantics; LLVM's BOLT is a post-link,
   profile-guided binary-layout optimizer aimed at large real-world
   binaries, not a match for this project's scale or need. What *does*
   exist, is mature, and is exactly the standard tool for this job is
   **`opt`** — LLVM's own optimizer — run over the IR before it's
   lowered to machine code by **`llc`**. Once codegen's output is LLVM
   IR, "add optimization" becomes routing that IR through `opt` at a
   chosen level before `llc` — no bespoke optimizer needed, satisfying
   the "not our own tool, at least for the first round" requirement
   directly.
2. **True separate compilation stops being a from-scratch design
   problem.** Each `.ptl` translation unit compiles to its own LLVM IR
   module, independently lowered by `llc` to its own object file,
   cached, and linked with the others — mechanically the same shape
   `Hoare/scripts/build.sh` already proves works today (multiple `.o`
   files linked with `ld`), just with `llc` producing each `.o` instead
   of `nasm`. `#include`'s forward-declaration convention (already in
   the grammar, §5.2, specifically for this use case) is what lets one
   unit type-check a call into another without needing that unit's full
   body — the piece §11 item 2 of the reference calls out as the harder,
   "touches linking" half of the problem is now mostly LLVM's linker's
   job, not ours.
3. **Composite values across calls stop needing a hand-rolled ABI.**
   This session's proof-of-concept codegen deliberately avoided any
   System-V-style struct-passing convention, inventing its own
   simplified one instead (`Stage1/README.md`'s codegen section) — doing
   struct-by-value parameter/return passing correctly by hand in raw
   x86-64 is exactly the fiddly, error-prone part real backends spend
   the most effort on. LLVM IR has aggregate (struct/array) types as a
   first-class concept, and `llc` already knows how to lower them
   per-target — this is precisely the class of problem an existing
   backend is best at, and precisely the class of problem worth *not*
   re-solving by hand a second time. This is also why it's sequenced
   **after** the LLVM IR switch rather than before: doing it once,
   directly against LLVM's own aggregate handling, is strictly less work
   than building a NASM-based version first and then redoing it for
   LLVM immediately after.
4. **Platform independence stops being a from-scratch design problem
   too.** Hoare's own x86-64-only reality already had to be corrected
   once at the language-design level — v1 §2.5 explicitly calls out
   pointer size as *platform-dependent*, not fixed at 8 bytes, "for a
   language whose stated goal is to eventually target more than one
   architecture." Emitting hand-rolled x86 NASM text keeps that goal
   permanently out of reach without a second, parallel backend for every
   new target; emitting LLVM IR gets it close to free, because the IR
   itself is already target-independent — the same `.ll` module `llc`
   lowers to x86-64 today lowers to AArch64, RISC-V, or anything else
   LLVM supports by changing `llc`'s target triple, with no change to
   codegen's own logic at all. This doesn't make Stage 1 multi-platform
   by itself (calling conventions, the raw-syscall `extern function`
   whitelist, and `_start`-style trampolines — §2's earlier note — are
   still per-target, hand-written pieces), but it removes the single
   biggest structural obstacle to ever attempting it, as a direct
   side effect of solving the optimization/separate-compilation problem
   this section is already about, not a separate effort.

Two implementation notes worth being explicit about, since they de-risk
what could otherwise look like a large rewrite of codegen's own logic:

- **Adopting LLVM IR does not require Stage 1's codegen to reason about
  SSA form.** The straightforward, standard technique (what `clang`
  itself does at `-O0`) is to keep exactly the structure codegen already
  has today — one stack slot (`alloca`) per local, a load before every
  read, a store after every write — and let `opt`'s `mem2reg` pass (part
  of any real optimization level) promote those to registers
  automatically. Codegen's own control-flow logic (`if`/`while`
  lowering, the statement-by-statement emission this session's
  `gen_stmt`/`gen_expr` already do) carries over structurally; what
  changes is which fixed-template text `emit_piece`-style dispatch
  produces — LLVM IR instructions instead of x86 mnemonics — not the
  shape of the code that decides *what* to emit.
- **This only changes Stage 1's own output.** Hoare (Stage 0) stays
  exactly what it is — a hand-written x86-64 NASM compiler — unaffected
  by anything in this plan. The toolchain Stage 1/Edsger depends on
  changes from `nasm`+`ld` to `llc`+`opt`+`ld` (or `clang` as a linker
  driver) starting at the step that makes this switch, below.

## 3. The rewrite point: where Edsger begins

**`v1.0.6` is the rewrite.** By this point, `#include` (`v1.0.1`), the
LLVM IR backend (`v1.0.2`), composite-call support (`v1.0.3`), true
separate compilation (`v1.0.4`), and real optimization (`v1.0.5`) all
already exist — in the still-single-file proof of concept, deliberately,
so the rewrite doesn't have to anticipate any of them, only use what's
already there.

`v1.0.6` itself does **no new language work at all** — it is a pure
architecture milestone, and deliberately scoped that way so its
correctness is easy to check (identical behavior, new shape): split the
lexer/parser/codegen trio into real, separately-compiled modules (a
lexer module, an AST/node module, a parser module, a codegen module, and
thin per-phase driver files), and replace the index-arena AST workaround
with a real pointer-linked struct tree — the workaround this session's
own design notes call out repeatedly as exactly that, a workaround
forced by v0 having no pointer-linked-tree story, not "Stage 1 form" in
any real sense. Verification is a full re-run of every fixture the proof
of concept already passed (Hoare's `cases`/`codegen_cases`/
`checker_cases`/`blackbox_cases`, plus this session's own multi-function/
operator correctness suite, plus whatever `v1.0.1`–`v1.0.5` each added
their own fixtures for), expecting identical, correct results — the
rewrite is not allowed to also be where new bugs sneak in.

From `v1.0.6` onward, the compiler is called **Edsger**. Everything
before it (`v1.0.1`–`v1.0.5`, and the original, unversioned proof of
concept) stays nameless — scaffolding that did its job.

## 4. Full step list

| Version | Adds | Why here |
|---|---|---|
| `v1.0.1` | `#include` (§6.2): relative-path resolution, recursive splice before lexing, include-once, cycle detection. Detailed design: [`postulate_stage1_v1_0_1_include_design.md`](postulate_stage1_v1_0_1_include_design.md). | Cheapest possible increment, zero dependency on anything else — see §1. |
| `v1.0.2` | Codegen backend switch: emit LLVM IR instead of x86 NASM text; `llc` replaces `nasm` for producing object code. Same scalar-only feature set as today — a backend swap, not a feature addition. | Foundation for the next three steps — see §2. Verified against the exact fixture suite the NASM backend already passes, proving the swap changes nothing observable yet. |
| `v1.0.3` | Composite (struct/array) parameters and return values in Stage 1's own codegen — v0 parity, not a v1 feature. Landed in internally-ordered sub-passes: width unification (**done**); structs — locals, field read/write, literals, struct-to-struct copy (**done**); arrays — locals, index read/write, literals (including array-of-struct), broadcast-init, array-to-array copy (**done**); struct/array-typed parameters and return values are still deliberately out of scope throughout (`type_ok` untouched — only `type_ok_local` accepts composites, decls only), and so are pointers (`&`/`*`, not yet done). Design: [`postulate_stage1_v1_0_3_composites_design.md`](postulate_stage1_v1_0_3_composites_design.md). | Implemented directly against LLVM IR's native aggregate types and per-target ABI lowering (§2) — done once, not once in NASM and then redone for LLVM. |
| `v1.0.4` | True separate compilation: each translation unit independently lexed/parsed/checked/compiled to its own LLVM IR module and object file, cached, linked together. | Reference §11 item 2, brought forward — see §2 for why this is now mostly LLVM's linker's job rather than a from-scratch design. |
| `v1.0.5` | Optimization turned on: each unit's LLVM IR routed through `opt` (an existing, off-the-shelf tool) at a chosen level before `llc`. | The other half of §2 — no bespoke optimizer needed; verified by re-running the full fixture suite and confirming behavior is unchanged under optimization. |
| **`v1.0.6`** | **Rewrite. Compiler renamed Edsger.** Same language surface as `v1.0.5` (v0 + `#include`); source reorganized into real, separately-compiled modules; AST rebuilt as a real struct/pointer tree. No new syntax. | The point marked in §3 — modularity, a real backend, separate compilation, and optimization all already exist, so the rewrite only has to *use* them, not anticipate them. |
| `v1.0.7` | Statement sugar: `elseif` (§4.3), `break`/`continue` (§4.6), compound assignment `:+ :- :* :/` (§4.2), `++`/`--` (§4.2a). | Pure desugaring, no new types — a low-risk first feature batch on the new modular codebase, exercising the rewrite before anything riskier lands on top of it. |
| `v1.0.8` | `as` explicit cast (§3.7a); `char` type, literals, escapes (§2.3). | `char` is unusable without `as` (its own arithmetic-by-casting example, §2.3); every later float/pointer step also needs `as`, so it lands once, here, not repeatedly. |
| `v1.0.9` | Floating point: `float32/64`, `ufloat32/64`, literals, `+ - * /`, comparisons incl. NaN, `**` (exponent), `_/` (root, desugars to `**`) (§2.4, §3.2). | Self-contained type family; reuses `as` from `v1.0.8` for every float conversion row in §3.7a's table. |
| `v1.0.10` | Pointer arithmetic, `*void`, `uintptr`, cross-type pointer comparison, `sizeof`/`lengthof` (§2.5–§2.7a). | Extends v0's already-working raw pointers; independent of floats/`char`, ordered after them only because it's needed for `v1.0.11` next. |
| `v1.0.11` | `main(argv, argc)` two-parameter form; atomic-only `main` return type, compiler-enforced (§6.3). | Needs `**char`/pointer-array understanding from `v1.0.10`; small and mostly checker-level, a good breather after `v1.0.10`'s codegen work. |
| `v1.0.12` | `ref` parameters (§5.3a). | Independent of the above; a calling-convention addition, not a type addition. |
| `v1.0.13` | Operator overloading (§5.4). | Needs nothing new beyond ordinary function-checking machinery; deliberately last of the "small features," since it's the least load-bearing for anything else in this list. |
| `v1.0.14` | Verification contracts, part 1: grammar, all seven contextual keywords (`requires`/`ensures`/`invariant`/`decreases`/`old`/`result`/`last`), full semantic validation (§7.1–§7.2, §7.6–§7.6b, §8.1). Zero runtime cost — a normally-compiled program emits no contract code at all. | The bulk of the contract system's genuine complexity (contextual-keyword parsing, purity checking, the no-self-reference rule) isolated from codegen risk; everything from `v1.0.7`–`v1.0.13` needs to exist first since contract expressions can mention any of it. |
| `v1.0.15` | Verification contracts, part 2: the opt-in checked-build codegen mode (§7.3–§7.5) — runtime assertions at every specified checkpoint, halt-with-diagnostic on failure. | Split from `v1.0.14` deliberately: parsing/checking a contract correctly and *emitting code* for one are separably testable, and this is the riskier of the two. |
| `v1.0.16` | Bounds-checking diagnostic build (§2.7b) — array indexing checked against `lengthof` in an opt-in build. | Same opt-in-diagnostic-build mechanism `v1.0.15` just built; reuses it rather than inventing a second one. |
| `v1.0.17` | Self-hosting closure: Edsger compiles itself (Hoare → Edsger₁ from source; Edsger₁ → Edsger₂ from the same source; Edsger₂'s output agrees with Edsger₁'s). | The actual bootstrap goal (`Stage1/README.md`'s opening line) — only meaningful once the full v1.0 surface exists, since Edsger's own source will by then use most of it. |

### Tracked checkpoint: struct-field layout, before `v1.0.6`

`v1.0.3`'s composite sub-pass represents struct fields packed, with
zero padding between them — matching v0's own language-level layout
guarantee exactly (`postulate_v0_language_reference.md` §2.6) via
LLVM's native packed struct type. Whether that guarantee itself should
ever change (e.g. toward natural/ABI alignment, for raw-memory-access
performance or a future FFI's sake) is **explicitly not decided now** —
deliberately deferred, not silently carried forward as permanent. This
is a placeholder to make sure it gets a real look before `v1.0.6`
(the Edsger rewrite) closes out the still-single-file proof-of-concept
era, rather than being forgotten between now and then.

## 5. What's deliberately not in this plan

Everything reference §11 lists as **explicitly deferred beyond v1**
stays deferred here too, for the same reasons given there, **except**
true separate compilation (§11 item 2), which §2/§4 above bring forward
as `v1.0.4`. Still out of scope for this plan: namespaces, static
(SMT-backed) verification, the `string`/console-I/O/threading standard
libraries, struct reflection, a general FFI, further preprocessor
directives, and any language-level data-race protection. None of them
are scheduled as a `v1.0.n` step; the first of them (namespaces) is
already earmarked as "v1.1" by the reference itself — a new document and
a new plan, once this one is finished, not a step folded into it.

## Beyond this plan

Once `v1.0.17` closes the self-hosting loop, Hoare (Stage 0) becomes
historical — every future change targets Edsger's own source, compiled
by itself. The next language generation (namespaces and whatever else
accumulates toward it, §11 item 1) becomes `v1.1`, with its own
reference document and its own version of this plan (`v1.1.n`) once
that design work happens — not a continuation of the numbers above.
