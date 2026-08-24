# `v1.0.4` design: true separate compilation

## Scope

This is the implementation design for step `v1.0.4` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md): **true
separate compilation** — reference §11 item 2, brought forward from
"deferred beyond v1" specifically because Stage 1/Edsger's own build
needs it. It lands on top of `v1.0.3` (composite parameters/return
values, pointers, the calling convention — all now done, see
[`postulate_stage1_v1_0_3_composites_design.md`](postulate_stage1_v1_0_3_composites_design.md))
and builds on `v1.0.1`'s `#include` machinery
([`postulate_stage1_v1_0_1_include_design.md`](postulate_stage1_v1_0_1_include_design.md)).

**This revision supersedes this design's own first draft**, which
proposed a program-wide, "everything `#include`-reachable shares one
flat namespace regardless of who included what" visibility model. That
model was rejected during review for a real reason, not a style
preference: it meant every unit's cache key depended on the *whole*
program's interface set, so a signature change anywhere invalidated
every unit's cache — exactly the "still one big compilation, just with
extra caching machinery bolted on" outcome true separate compilation is
supposed to avoid in a large codebase. It also let one file call into
another's function *without* declaring that dependency itself (visible
only because some third file happened to include both), which conflicts
with the project's own stated design principle that everything should
be explicit and checkable by looking at one thing. Both problems trace
to the same root cause, and both are fixed by the same change: **scope
visibility to what a file itself, directly, declares needing** —
detailed below, and now specified at the *language* level, not just as
a Stage 1 implementation detail. That language-level change is real and
is documented in
[`postulate_v1_language_reference.md`](postulate_v1_language_reference.md)
§1.3/§6.2 directly, alongside worked examples — this document only
covers how Stage 1 *implements* the rule §6.2 now specifies, not the
rule's own rationale (§6.2 makes that case in full; skimming it before
this document is worthwhile).

## The rule this design implements, restated briefly

(Full rationale, and the worked examples, live in §6.2 — this is a
short restatement so the rest of this document reads on its own.)

- A file that `#include`s another gets **full, unqualified access** to
  everything that file declares at its own top level — every function,
  every `extern function`, every struct.
- That access is **not transitive for functions/`extern function`s**:
  including `B.ptl`, which itself includes `C.ptl`, does not grant
  access to anything `C.ptl` declares — only to what `B.ptl` itself
  declares.
- **Struct types are the one deliberate exception**, and only as far as
  actually needed: a struct mentioned in the signature of something you
  can already see is visible too, however many files away it was
  originally declared. A struct never in scope this way still requires
  its own direct `#include`.
- That exception covers **consuming** a propagated struct type only — a
  *local's* type annotation, reading a field, passing a value along,
  whole-value assignment — never **authoring or re-exposing** one.
  Constructing a struct literal, or writing the type into a function
  signature or struct field list *you yourself declare*, both still
  require directly `#include`ing the file that declares that struct;
  otherwise your own file would silently become a further, undeclared
  carrier of it to whoever includes you next. A struct's own **layout**
  (needed for codegen, e.g. a field that's itself another struct from a
  third file) still propagates automatically and fully, regardless of
  ownership — only which type *names* a file's own source may write in
  an authoring/exposing position is restricted.
- Name-collision checking is correspondingly **only as wide as
  visibility** — two files with no `#include`/struct-propagation
  relationship to each other may declare the same name without either
  one, or anything checking either one in isolation, ever noticing.

## Translation units

A **translation unit** is one file — the same file table `v1.0.1`
already builds during its "Phase 1 — Discover" (`file_path_off/len`,
`file_content_off/len`, `file_body_off`, the `dep_pool`/topological-
order machinery), unchanged. Discovery, path resolution, include-once,
cycle detection, and the preamble-position rule all stay exactly as
`v1.0.1` shipped them — `v1.0.4` is a *consumer* of that graph and its
topological order, not a revision of either. What changes is what
happens **after** discovery: instead of Phase 3 ("Emit") concatenating
every file's body into one buffer for one compile, each file's body
becomes the input to its own, independent lex → parse → check → codegen
pipeline, run once, cached, and linked against the others afterward.

The topological order `v1.0.1`'s Kahn's-algorithm phase already
produces (leaves first, the entry file last) is reused here for a
different reason than before: it's still the order interface
computation (next section) has to happen in, since a file's interface
can depend on a struct closure computed for one of its own
dependencies, which must therefore already be known.

## Interface extraction

For each file `i`, in topological order, compute its **interface** — a
compact record of exactly what `i` makes available to a file that
`#include`s it, per the rule above:

- `own_functions(i)`: every `function`/`pure function` `i` declares at
  its own top level, recorded as (name, the *signature text span* —
  everything from `function`/`pure function` through the return type,
  which parsing already delimits exactly, since that's precisely where
  a body would otherwise begin).
- `own_structs(i)`: every `struct` `i` declares at its own top level,
  recorded as (name, its *whole declaration's text span* — structs have
  no signature/body split to exploit, §5.1 unchanged from v0, so the
  only usable form is the complete field list, verbatim).
- `struct_closure(i)`: every struct type mentioned anywhere in
  `own_functions(i)`'s parameter/return types or `own_structs(i)`'s own
  field lists that is *not* already in `own_structs(i)` — resolved
  against `i`'s own **direct** dependencies' `own_structs` (only —
  never a dependency's own `struct_closure`; see why below).

**Ownership check, enforced while parsing `i`'s own top-level
declarations, before `struct_closure(i)` is even computed**: every
struct type named in `own_functions(i)`'s signatures or `own_structs(i)`'s
field lists must be either declared locally by `i` or `own_structs(d)`
for some `d` in `i`'s own **direct** `#include` list — never merely
`struct_closure(d)` (something `d` itself only consumes, not owns).
This is §6.2's "consumed, never authored or re-exposed" rule, checked
at exactly the point it has to be: `i` cannot put a type it doesn't own
into anything `i` itself exposes. A reference that fails this check is
a compile error (`Pair` used in `still_broken`'s parameter list or
`Wrapper`'s field list, in §6.2's own example, without `#include
"./c.ptl";` in that same file).

**This check is what makes `struct_closure(i)` provably only ever one
`#include` hop deep, for any file that actually compiles.** Since `i`'s
own exposed declarations can only ever name types `i` owns directly
(locally declared, or from a direct dependency's `own_structs`),
`struct_closure(i)` never needs to reach into a dependency's own
further-propagated `struct_closure` — there is nothing there `i` could
have legally referenced in the first place. Interface propagation is
therefore always exactly one hop per `#include` edge, computed as a
plain lookup against direct dependencies' `own_structs`, not a
multi-file recursive walk — simpler than this design's own first
attempt at this section assumed, and a direct, structural consequence
of the ownership check above rather than a separate optimization.

**Construction/exposure eligibility for struct `S` in file `i`**:
legal exactly when `S` is declared locally by `i`, or `S ∈
own_structs(d)` for some `d` in `i`'s own **direct** `#include` list —
the same membership test the ownership check above already performs,
reusable as-is anywhere a struct literal or an outbound signature/field
needs checking.

**Layout propagation is a separate, unrestricted concern, computed
independently of the two rules above.** A struct's field that is itself
another struct — however many files away *that* struct's own true
declaration lives — always needs its full field layout available
wherever the outer struct is compiled, purely so `llc` can lower the
aggregate correctly; this has nothing to do with which type names a
file's own source is allowed to write, and is never restricted by
ownership. Concretely: if `own_structs(i)` (or something `i` legally
exposes) contains a struct whose own field list mentions a type from a
file two or more hops away, the driver's synthesized input for any file
using it (see "Compiling one unit for real" below) still needs that
distant struct's full text spliced in, recursively, regardless of
whether the compiling file itself "owns" it in the naming sense —
codegen needs the bytes; the ownership check only ever gates what a
file's own *source text* may spell out.

`interface(i) = own_functions(i) ∪ own_structs(i) ∪ struct_closure(i)`.
This is computed by running the **existing** lexer/parser over
`source_pool[file_body_off[i] .. file_content_off[i]+
file_content_len[i])` — `v1.0.1`'s own already-isolated per-file body
span, no new scanning logic — and walking its top-level declarations,
exactly what `build_func_table`/`build_struct_table` in `codegen.ptl`
already do today as a subroutine of compiling the whole merged program;
`v1.0.4` runs the same walk once per file instead of once per program,
seeded with the direct dependencies' already-computed interfaces
instead of the whole file's own transitive closure.

**What a file's real compile actually sees**: for file `i`, the union
of `interface(d)` for every `d` in `i`'s own **direct** `#include`
list — never `i`'s transitive closure, and never the whole program.
This is the one load-bearing difference from this design's first draft,
and it's what gives caching (below) the locality property this
revision exists to provide: `i`'s cache key only depends on `i`'s own
body and the interfaces of files `i` itself names, so a change
somewhere `i` doesn't depend on, directly or through struct
propagation, never touches `i`'s cache entry at all — not "rarely," not
"unless it happens to be reachable," but structurally never, by
construction of the rule itself.

### Three required, narrowly-scoped additions on top of what exists today

The first two are unchanged from this design's first draft — the
visibility model changed, but the mechanics of turning a foreign
interface into something the existing pipeline can compile against did
not. The third is new, needed specifically for the ownership check to
be enforceable inside a unit's own function *bodies*, not just at
interface-extraction time against its top-level declarations.

#### 1. Pulling forward bodyless function forward declarations

v0 has no way to declare a function's signature without its body — a
`function_decl` is always `signature { ... }`. v1 §5.2 already designs
the fix, and names the exact use case this design needs: "a forward
declaration (no body, terminated by `;` instead of a `func_block`) …
useful once `#include` lets a signature live in one file and its
definition in another." `v1.0.4` pulls forward **only** the bodyless
form itself —

```ebnf
function_decl ::= ("pure")? "function" identifier "(" params? ")" ":" return_type (func_block | ";")
```

— **not** the contract-block grammar the full v1 production carries
alongside it (`v1.0.14`'s own scope, needing a purity checker Stage 1
doesn't have yet). This is the same kind of narrow, deliberate,
documented v1 exception `v1.0.1` (`#include` itself) and `v1.0.2`
(left-to-right argument evaluation) already are — a third entry in
`Stage1/README.md`'s "One narrow, deliberate exception" list, not a
precedent for grabbing more of v1 early.

**This mechanism is deliberately Stage-1-internal, never user-facing.**
A `.ptl` file's author never writes a standalone forward declaration for
a function defined elsewhere — the *only* sanctioned way to declare "I
depend on this" is `#include`ing the file that defines it, per the
language-level rule above. Exposing bare forward declarations as
ordinary user syntax was considered and deliberately rejected: it would
let a file reference a symbol with no traceable `#include` naming where
that symbol actually lives, resolved only by whatever else happens to
land on the same final link line — precisely the kind of non-local,
unverifiable coupling this whole redesign exists to rule out. Forward
declarations exist here purely as the mechanism the *driver* uses to
hand a unit's compile the signature of something it's allowed to call
without also handing it that thing's body — real, load-bearing work
(it's what makes a unit's own compile independent of its dependencies'
implementations at all), just not a piece of surface syntax.

A synthesized forward declaration for a foreign function is therefore
just that function's recorded signature span (from the interface record
above), with `;` appended in place of the `{ ... }` the real declaration
actually has.

#### 2. Relaxing "exactly one `main`" to a two-level check

Today, `codegen.ptl`'s main-scanning pass (`Stage1/src/codegen.ptl:7002`
onward) requires **exactly one** zero-parameter `main` across the
single merged program it compiles. Once most units don't contain `main`
at all (the ordinary case — only one file in a real program ever
defines it), this becomes:

- **Per unit**: `codegen.ptl`, compiling file `i`'s own real body (never
  a synthesized foreign forward declaration, which is bodyless and so
  can never be a `main` *definition*), enforces **at most one** local
  `main`. Zero is fine.
- **Per program**: delegated to the linker, not a bespoke Stage 1 pass
  — see "Duplicate names and `main`-count move to the linker" below.

#### 3. Marking propagated-only structs so the ownership check reaches inside function bodies too

Interface extraction enforces the ownership check (§6.2's "consumed,
never authored or re-exposed" rule) against `i`'s own top-level
declarations — but a struct literal for a non-owned type can just as
easily appear **inside a function body**, deep in an expression, not
only in a signature or a field list. That has to be caught during `i`'s
*real* compile, which means the synthesized input handed to
`codegen.ptl` needs to let the checker tell, for every struct name in
scope, whether `i` owns it (`own_structs(d)` for a direct dependency
`d`, or declared locally) or only received it on propagated,
consume-only visibility (`struct_closure(d)` for a direct dependency
`d` — one hop only, per the simplification above).

Structs, unlike functions, have no existing bodyless form to reuse for
this (§5.1's own point — a struct's only usable form is its complete
field list, needed for layout regardless of ownership). `v1.0.4`
therefore reuses `extern`, already meaning "declared here, not owned
here" for `extern function` (v0 §5.2's syscall whitelist), for
propagated-only structs too — full field list still present (layout is
never withheld), just tagged:

```postulate
extern struct Pair { first : int32; second : int32; }
```

vs. the ordinary, owned form (spliced verbatim from `own_structs(d)`
for a directly-included `d`, or written locally):

```postulate
struct Pair { first : int32; second : int32; }
```

**This too is deliberately Stage-1-internal, never user-facing** — the
same reasoning as the forward-declaration form above applies
identically: a `.ptl` author never writes `extern struct` by hand, it
exists only in driver-synthesized input, and the *only* sanctioned way
for a real `.ptl` file to gain construction rights over a struct is its
own, real `#include`. The checker's existing struct-literal type
resolution gains one more test alongside its ordinary name lookup: if
the resolved struct came from an `extern struct` entry, a literal for
it is a compile error, with the same diagnostic §6.2's own examples
describe (`also_broken`/`still_broken`/`Wrapper`); if it came from an
ordinary `struct` entry (owned, whether declared locally or spliced
from a direct dependency's `own_structs`), construction is fine.

### Duplicate names and `main`-count move to the linker, not a whole-program pass

This design's first draft added a dedicated whole-program interface
table specifically to check two things across every unit at once:
colliding top-level names, and exactly-one-`main`. **Neither needs
that anymore.** Since visibility (and therefore what "collision" even
means) is now scoped to what a single file can see, a same-named
`struct Point` in one file and `function Point(...)` in another are
only a *language*-level problem if some third file's own visible set
ever contains both — which is already checked, for free, by that third
file's own ordinary compile (the existing single-file duplicate-name
logic `build_func_table`/`build_struct_table` already has, now seeded
with a narrower, direct-dependency-only interface set instead of a
whole-program one, but otherwise unchanged). Two files that never see
each other may harmlessly share a name — per §6.2's own "consequence
worth stating plainly" — and if both still end up in the same final
linked binary regardless, that surfaces as an ordinary duplicate-symbol
error from **`ld` itself**, the same way two unrelated C translation
units defining a colliding externally-linked symbol only ever find out
at link time. Likewise, if every unit's codegen emits `main`'s
compiled body (and the `_start` trampoline that calls it, sized to its
declared return width per `v1.0.2`) under one fixed, well-known external
symbol name, then "zero `main`s across the program" is `ld`'s ordinary
"undefined reference," and "more than one" is its ordinary "multiple
definition" — both already exactly what `Hoare/scripts/build.sh`'s
existing multi-`.o` links would produce for any other colliding symbol,
nothing new to build. **This removes an entire phase** (whole-program
interface-table construction, plus two bespoke checks) this design's
first draft needed and this one doesn't — a direct, structural
consequence of narrowing visibility, not a separate simplification
decided independently.

## Compiling one unit for real

For file `i`, the input handed to the *existing*, unmodified
lex → parse → check → codegen pipeline is a small **synthesized
program**, assembled by the driver, ordinary v0+v1 source text, in this
shape:

1. For every file `d` in `i`'s own **direct** `#include` list:
   `own_structs(d)`'s entries, verbatim, as ordinary, owned `struct`
   declarations — `i` may both use and construct these, since `i`
   directly includes their true home, `d`.
2. The same direct dependencies' `struct_closure(d)` entries — types
   `d` itself only consumes, from files `i` doesn't directly include —
   as `extern struct` entries (full field list, tagged non-
   constructible per addition #3 above).
3. Recursively, for any struct spliced in either of the above two
   steps whose own field list mentions a struct not yet included, that
   struct's full text too — pure layout completion (addition #3's own
   "layout propagation is separate and unrestricted" point), tagged
   `extern struct` regardless of source, since nothing about needing a
   field's layout grants `i` construction rights over it.
4. The same direct dependencies' function entries, reduced to bodyless
   forward-declared form (signature span + `;`).
5. File `i`'s own real body, verbatim, byte-for-byte unchanged.

This is fed to the codegen pipeline exactly as a full merged-`#include`
program is fed to it today — no new "modes," no argv, no sidecar
format, consistent with every Stage 1 phase being a pure stdin → stdout
filter (`Stage1/README.md`'s "why everything here looks the way it
does"). Diagnostics inside `i`'s own real body report `i`'s own native
line numbers directly — no merged-buffer offset remapping is needed at
all here (unlike `v1.0.1`'s own "Diagnostics under this model," which
exists only because *that* design concatenates multiple *real* bodies
into one buffer; here exactly one real body is ever present in any
single compile).

`codegen.ptl`'s output for unit `i` is its own LLVM IR module, lowered
by `llc` to its own object file — `i.o` — exactly `v1.0.2`'s existing
single-module path, invoked once per unit instead of once per program.

**Struct type identity across units needs no special handling.** LLVM
does not require identically-named struct types in two separately
compiled modules to share cross-module identity; what has to agree
across a call/return boundary is the **memory layout** `llc` lowers it
to, and that agrees automatically here because both units generated
their copy of the struct from the *same interface text* — the packed,
zero-padding layout (`v1.0.3`) is a pure function of the field list,
byte-identical wherever it's reproduced.

## Caching

**Cache key for unit `i`**: a hash of (file `i`'s own real body bytes)
concatenated with (the interfaces of `i`'s own **direct** `#include`
targets only, serialized in a fixed order — e.g. declaration order in
`i`'s own preamble). **Cache value**: `i`'s already-built object file.
Storage is plain content-addressed files on disk (`<hash>.o`) —
existence of `<hash>.o` **is** the cache-hit test, no separate manifest
needed, the same instinct `v1.0.1`'s include-once (no `visiting` flag)
already follows.

**This is the property this whole revision exists to secure, so it's
worth stating precisely.** Editing file `Z` invalidates unit `i`'s
cache entry **if and only if** `Z` is one of `i`'s own direct
`#include` targets *and* the edit changed `Z`'s interface (a signature,
or a struct field list) — never `i`'s own body-only edits to *other*
functions, and never anything about a file `i` doesn't itself name,
no matter how large or central that file is elsewhere in the same
codebase. Concretely, in a codebase with a thousand files: touching one
leaf file's function *body* recompiles exactly that one file; touching
its *signature* recompiles it and whatever finite set of files actually
name it directly (plus, transitively, whatever those files' own
dependents are, since their own interfaces may have changed too) — not
the thousand. This is the direct fix for the first draft's "everything
is one compilation unit, just cached" outcome: there, *any* signature
change anywhere invalidated *every* unit's cache, because visibility
(and therefore the cache key) was program-wide; here, a cache key only
ever contains what a file actually, explicitly said it depends on.

**Known, accepted limitation, deliberately not solved now**: the cache
key includes a dependency's *entire* interface, not just the specific
names `i` actually uses from it — editing an unrelated function's
signature in a file `i` `#include`s for one other function still
invalidates `i`, even though `i` never referenced the changed one. A
finer key (only the subset of a dependency's interface actually
referenced) is a legitimate future refinement, not attempted here, for
the same reason `v1.0.1`'s symlink limitation wasn't closed either — it
costs real design weight for a narrower win than the fix this revision
already makes.

## Why the orchestration has to live outside Postulate itself

Unchanged from this design's first draft: none of "hash a file, check
whether `<hash>.o` exists, invoke `llc`, invoke `ld`" can be done from
inside a Stage 1 binary — the `extern function` whitelist (v0 §5.2) has
no process-spawning syscall, and adding one is a far larger, more
dangerous surface than `v1.0.1`'s own `sys_openat`/`sys_close` addition
was, not proposed here. The orchestration is necessarily a **driver
script outside the language** — e.g. `Stage1/scripts/build_program.sh`
— mirroring `Hoare/scripts/build.sh`'s existing multi-`.o` link shape:

1. Run discovery (`v1.0.1`'s Phase 1/2, see "Where discovery runs now"
   below) to get the file table, direct-`#include` edges, and
   topological order.
2. In topological order, compute `interface(i)` for each file (parser
   invocation per file).
3. For each file, compute its cache key from its own body plus its
   direct dependencies' interfaces; on a miss, assemble its synthesized
   input (its dependencies' interfaces + its own real body), run it
   through `codegen`, then `llc`, and store the result at `<hash>.o`;
   on a hit, reuse the existing `<hash>.o` untouched.
4. Run `ld` once over the full object set (freshly built and cache-hit
   objects mixed) — mechanically identical to `Hoare/scripts/build.sh`'s
   existing link, `llc`-produced objects instead of `nasm`-produced
   ones per `v1.0.2`, and where "Duplicate names and `main`-count move
   to the linker" (above) actually gets enforced.

**This is expected to be a permanent property of the design**, not
something `v1.0.6`'s rewrite or `v1.0.17`'s self-hosting closure later
absorbs into the language — the orchestration always needs to invoke
external processes (`llc`, `ld`, and Edsger's own repeated invocations
of itself), something nothing in this plan gives Postulate programs the
ability to do from inside the language.

### Where discovery runs now

`v1.0.1`'s "Phase 1 — Discover" is itself file-reading logic that can't
easily move outside Postulate without duplicating
`sys_openat`/`sys_read`/`sys_close` in the driver's own language. This
design keeps discovery exactly where it already lives —
`codegen.ptl`'s own copy of `resolve_includes` — and gives the driver a
way to *ask* for the resulting file table and each file's interface
without also demanding a full compile: a fifth, driver-only "dump the
file graph and interfaces" mode, printing (per file) its resolved path,
its own **direct** `#include` targets by index, and its computed
`interface(i)` (function signature spans, struct spans), to stdout.
Distinguished from an actual per-unit compile purely by what's on the
driver's end, never a property visible to a compiled Postulate program
— the same precedent `v1.0.1` already set with the token dump and the
AST dump as their own bounded, phase-specific output formats.

## What this deliberately does not touch

- **`#include`'s own file-discovery mechanics** — path resolution,
  include-once, cycle detection, the preamble-position rule — all
  exactly as `v1.0.1` shipped them.
- **`lexer.ptl` and `parser.ptl`'s own standalone full-merge modes** —
  unchanged: whole-program token-dump and whole-program AST-dump tools,
  useful for inspecting a fully-spliced program as a diagnostic aid, not
  part of the build-a-running-binary path. Only `codegen.ptl`'s
  pipeline, and the new external driver, are in scope here.
- **User-facing forward-declaration syntax** — deliberately not
  introduced; see "This mechanism is deliberately Stage-1-internal"
  above.
- **Parallel compilation of independent units** — the dependency graph
  would permit it (no unit's compile reads another unit's *body*, only
  its already-extracted interface), but this design compiles
  sequentially in topological order. A parallel driver is a plausible
  future refinement, not required for correctness here.
- **Cross-unit optimization/LTO** — `v1.0.5` routes each unit's own IR
  through `opt` independently; nothing here attempts whole-program
  inlining across the unit boundary this design introduces.
- **Finer-than-direct-dependency cache keys** — see "Known, accepted
  limitation" under "Caching."
- **Contracts riding on forward declarations** — out of scope until
  `v1.0.14`; the bodyless-function grammar pulled forward here is
  deliberately the bare minimum.

## Migration note: one existing fixture tests the rule this design removes

`Stage1/tests/include_cases/13_transitivity_siblings` (`v1.0.1`) has
`main.ptl` `#include` `b.ptl` and `e.ptl`, then call `c_val()`/`d_val()`
— functions declared in `c.ptl`/`d.ptl`, reachable only because `b.ptl`
itself includes them, `main.ptl` never does. That fixture exists
specifically to prove the old, program-wide transitivity rule worked
correctly across a non-linear graph — exactly the pattern §6.2 now
rejects. It is expected to stop compiling once `v1.0.4` (and its
language-level prerequisite, the §6.2 rewrite) land, and will need
rewriting (each file `#include`ing what it actually calls directly) or
retiring as part of `v1.0.4`'s own implementation — not fixed by this
design document, called out here so it isn't a surprise during that
work.

## Testing plan

1. **Full regression, adjusted for the new rule.** Every existing
   `include_cases`/`codegen_cases` fixture compiled through the new
   per-unit + cache + link path must produce the same behavior as
   today, **except** `13_transitivity_siblings` (above), which is
   expected to need rewriting under the new rule, not to keep passing
   unmodified.
2. **Direct inclusion grants full function access** — the `a`/`b`/`c`
   "`helper`" example from §6.2: `b.ptl` calling `c.ptl`'s function
   (direct include) succeeds; compiled and run.
3. **Transitive function access is rejected.** The same shape, but with
   `a.ptl` (which only includes `b.ptl`) attempting to call `c.ptl`'s
   function directly — must be a clean compile-time diagnostic ("name
   not visible" or equivalent), not a codegen-time crash, and not a
   silent success.
4. **Struct closure propagates; the function that produced it does
   not** — the §6.2 "`Pair`/`make_pair`/`wrap_pair`" example: `a.ptl`
   using `Pair` (returned by `wrap_pair`, which `a.ptl` can see) must
   compile and run correctly; `a.ptl` calling `make_pair` directly must
   still be rejected, confirming struct propagation and function
   non-propagation are checked independently, not that one accidentally
   grants the other.
5. **Multi-hop struct closure.** A struct field itself typed as another
   struct declared in a third, more distant file (two propagation hops)
   resolves and round-trips correctly.
6. **`main` in a non-entry file**, and the two-level check: a unit
   defining `main` links correctly regardless of which file it's in;
   zero units defining `main` across the program produces `ld`'s
   undefined-reference diagnostic; two units each defining a real
   `main` produces `ld`'s multiple-definition diagnostic.
7. **Same-named, mutually-invisible declarations don't collide.** Two
   files, neither `#include`ing (or struct-propagating from) the other,
   both declaring a function with the same name, both used (via their
   own, separate includers) elsewhere in the same overall program —
   compiles and runs correctly, confirming collision-checking really is
   scoped to visibility per §6.2's own "consequence worth stating
   plainly," not silently still whole-program.
8. **Cache hit skips real work.** Build once; build again with no
   source changes; confirm (via the driver's own accounting) no unit is
   re-parsed/re-codegen'd/re-`llc`'d, and the linked binary is
   byte-identical.
9. **Body-only edit invalidates exactly the one edited unit** — edit a
   function body without changing any signature; rebuild; confirm only
   that file's object regenerates.
10. **A dependency's signature edit invalidates only its actual
    dependents, not the whole program.** In a graph with at least one
    file that does **not** depend, directly or transitively, on the
    changed file, confirm that unrelated file's cache entry is
    untouched after the edit and rebuild — the direct test of this
    revision's whole reason for existing.
11. **A foreign function's forward declaration never leaks as a
    callable name beyond the unit it was synthesized for** — confirms
    the internal-only synthesis mechanism doesn't accidentally widen
    visibility beyond what interface extraction actually computed.
