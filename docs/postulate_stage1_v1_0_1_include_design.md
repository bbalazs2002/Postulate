# `v1.0.1` design: `#include`

## Scope

This is the implementation design for step `v1.0.1` of the
[Stage 1 bootstrap plan](postulate_stage1_bootstrap_plan.md): `#include`
(v1 reference §6.2), and nothing else — no LLVM, no separate
compilation, no new types. It lands on top of the still-single-file
proof of concept (`Stage1/src/lexer.ptl`/`parser.ptl`/`codegen.ptl`),
each still its own stdin → stdout filter, exactly as today.

Restating the target semantics from §6.2, since the design below is
built directly against it: `#include "path";` is a **preprocessing-time
textual splice**, performed before lexing begins, not part of the
token/AST grammar. `path` is everything between the two `"` characters,
resolved **relative to the file containing the `#include`**. Two
properties are automatic: **include-once** (a file already spliced in
anywhere in the inclusion graph is silently skipped on a repeat), and
**cycle detection** (including something currently being spliced is a
compile error, not an infinite loop).

**Terminated by `;`, not by the newline** — matching every other
statement/declaration in the language (§1.1's "no
statement-terminating newlines"), and specifically so `#include` isn't
the one construct that can't share a physical line with anything else.
The practical consequence for this design: the splice pass can **no
longer anchor its scan on "start of a line"** the way an earlier draft
of this design did — a directive can now appear mid-line, after other
code, or several to a line, so the scanner has to look for the literal
sequence `#include "` wherever it occurs in ordinary (non-comment)
text, not just at column 1. See "Comment-awareness" below for the one
real complication this introduces.

**The quotes are mandatory, not optional punctuation.** Per §6.2's own
note, they reserve syntax space for a possible future `#include
<path>` form (a different, not-yet-designed resolution mode) without
spending it now — `v1.0.1` implements *only* the quoted form.
`#include` followed by anything other than a `"..."` path (bare text,
`<...>`, no path at all) is a preprocessing-time diagnostic, the same
severity as a cycle or a missing file — not silently accepted, and not
silently reinterpreted as the reserved future form, since that form has
no defined meaning yet to fall back to.

**Every `#include` must precede any other content in its own file,
comments excepted** (§6.2 — readability: a file's dependencies stay in
one place, at the top, never scattered through the body). This is a
second reason the scanner can't stop at "recognize a directive wherever
`#include "` occurs" — it also has to track, per file, whether it has
already seen non-comment, non-directive content, and reject a
directive found afterward with its own specific diagnostic rather than
either accepting it late or letting it fall through to a confusing
generic parse error later. See "Comment-awareness" below for exactly
where this check sits in the scanner.

**The per-file rule above is required to hold *transitively*, across
the whole assembled program, not just locally in each file taken on its
own.** Concretely: included content must land at the very front of
*the file's own body* — not at the textual position of the `#include`
that pulled it in — and this applies recursively, so that an included
file's own includes are themselves fully resolved (and moved to the
front of *that* file's body) before that file's own content is used to
satisfy anyone else's dependency. A naive "replace the `#include` token
with the target file's text, in place" splice does not automatically
give this: whether the shallow, one-directive-at-a-time substitution
happens to end up satisfying it depends on details of how deeply nested
files interleave, and reasoning about that case by case is exactly the
kind of thing worth not doing by hand. The fix isn't a smarter
in-place substitution — it's a different algorithm, built around a
**dependency graph and a topological order**, in "Resolution algorithm"
below (recursion appears only as the *specification* of that order, per
the definition there — the actual implementation is queue-based, no
recursive calls, no per-directive buffer insertion). "Diagnostics under
this model" (further below) works out the file/line consequence in
full — worth its own section, since it's the one place this design
choice has a real, non-obvious effect on something else already built.

## The blocking gap: there is no way to open a file

This is the first, and biggest, real finding of this design pass, and
it has to be resolved before anything else here matters.

Every Stage 1 binary today is a pure stdin → stdout filter — v0's `main`
takes zero parameters (no argv), and the `extern function` whitelist
(v0 §5.2, unchanged in v1 §5.2 except `sys_mmap`'s return type) is:
`sys_read`, `sys_write`, `sys_mmap`, `sys_munmap`, `sys_mremap`,
`sys_exit`, `sys_exit_group`, `sys_clone`, `sys_futex`, `sys_gettid`.
**None of these can open a file by path.** `sys_read` only reads from an
*already-open* file descriptor — today that's always fd 0 (stdin),
handed to the process by whatever invoked it (`hoare`'s CLI wrapper does
the one-file case today via shell redirection, `"$CODEGEN" < "$input"`,
which is exactly why this has never come up before). `#include`
fundamentally needs the compiler itself to open additional files, by a
path it computes at runtime — a wrapper script can't pre-open an
unbounded, recursively-discovered set of included files on the
compiler's behalf.

**Proposed fix: add `sys_openat` and `sys_close` to the `extern
function` whitelist**, in both the language reference (v1 §5.2's table)
and Stage 1's own recognized-extern list:

| Name | Signature | Linux x86-64 syscall |
|---|---|---|
| `sys_openat` | `(dirfd: int64, path: *char, flags: int64, mode: int64) : int64` | 257 |
| `sys_close` | `(fd: int64) : int64` | 3 |

`openat` (not the older `open`) is the deliberate choice — it's the
modern, kernel-recommended form (`open` is even absent on some newer
architectures), and its `dirfd` parameter is irrelevant here: Stage 1
always resolves a path to a full string first (below), then calls
`sys_openat(AT_FDCWD, resolved_path, O_RDONLY, 0)` — `AT_FDCWD` (`-100`)
makes it behave exactly like `open` for a path that's either absolute or
relative to the process's own cwd, which is all that's needed since path
resolution itself (relative-to-including-file) is done by Stage 1's own
string logic, not left to the kernel.

This is not a Stage-1-internal hack bolted on outside the language — a
program with `sys_mmap`/`sys_munmap` but no way to open any file besides
the three inherited descriptors (stdin/stdout/stderr) is a real,
general gap, worth closing in the language's own extern table for every
v1 program, not just the compiler. It's the same kind of small,
justified whitelist addition `sys_munmap`/`sys_mremap` already were
(v1 §5.2's own note: "closing an obvious gap"). This addition should be
folded into `v1.0.1` itself, not treated as a separate step — `#include`
cannot be implemented without it.

`char` doesn't exist yet at `v1.0.1` (that's `v1.0.8`) — `path`'s type
above is written as `*char` to match the eventual §5.2 table exactly,
but until `v1.0.8` lands, Stage 1's own implementation reads/writes
paths as `*uint8` internally (exactly like `sys_read`'s existing `buf`
parameter) and only the public signature needs to already say `*char`,
consistent with how a forward-declared signature can exist before every
feature it mentions is fully usable elsewhere.

## Where the pass lives

A new function, conceptually `resolve_includes`, runs **before**
tokenization, in every one of `lexer.ptl`/`parser.ptl`/`codegen.ptl`
(tripled, like everything else in the proof of concept — this is
exactly the duplication cost `v1.0.6`'s rewrite exists to remove, not a
new problem `#include` introduces). Today's `main()` in each file reads
stdin into a single `src_buf` and hands it straight to `tokenize_all`;
`resolve_includes` becomes a new stage in between: internally it runs
the three phases in "Resolution algorithm" below (discover → order →
emit) and hands back one merged output buffer — that buffer, and only
that buffer, is what gets tokenized. Nothing downstream of tokenization
changes at all; `resolve_includes` is a single, self-contained
replacement for "read stdin into `src_buf`," not three separately
exposed steps.

## Data structures

No struct-typed arrays, no composite values crossing a function call —
`v1.0.1` still runs on top of Stage 1's *current* codegen, and
composite-across-calls parity doesn't land until `v1.0.3` (LLVM), well
after this step. Every structure below is therefore the same flat,
parallel-scalar-array shape `Buffers`/`PState`/`GState` already use
throughout `Stage1/src/*.ptl` — a `FileInfo[64]` "struct" is really six
`uint64[64]` arrays sharing an index, not an actual `struct` array.

Per known file (indexed 0..`file_count`, `file_count ≤ 64` — same
"cheap to be generous" cap `AST_ARENA_SIZE` already used this session):

- `file_path_off/file_path_len : uint64[64]` — its resolved, lexically-
  normalized path (into a small path-string pool), the include-once
  dedup key and what a diagnostic eventually names.
- `file_content_off/file_content_len : uint64[64]` — its raw bytes,
  read once via `sys_openat`+`sys_read`+`sys_close`, into a shared
  `source_pool` buffer (files simply appended one after another as
  discovered — no per-file fixed-size buffer needed).
- `file_body_off : uint64[64]` — where, within its own content span,
  the body actually starts (i.e. `file_content_off[i]` plus however
  many bytes its own leading comments/`#include`s occupied) — computed
  by the comment-aware scanner, "Comment-awareness" below.
- `file_body_line : uint64[64]` — the 1-based line number, *within that
  file*, where `file_body_off[i]` sits (counted during the same scan,
  by counting newlines up to that point) — this is what makes
  diagnostics work correctly under the new model; see "Diagnostics
  under this model" below.
- `file_dep_start/file_dep_count : uint64[64]` — a `(start, count)` pair
  into a shared `dep_pool : uint64[256]`, holding this file's own
  `#include` targets' file-indices, in the order they were written —
  exactly the list-pool pattern `parser.ptl`'s own `list_pool` already
  established this session, reused here for the same reason (a variable-
  length, per-owner list of ids).
- `file_indegree : uint64[64]` — how many *unresolved* dependencies this
  file still has; starts equal to `file_dep_count[i]`, decremented during
  topological ordering ("Resolution algorithm" below). A file reaches
  the front of that phase's queue exactly when this hits 0.

Plus one flat, order-tracking list, filled in by "Resolution algorithm"
below: `mut order : uint64[64]`, `mut order_count : uint64 := 0` — the
final topological order, file-indices, the order their body spans get
concatenated in.

**Include-once** falls out of the file table itself: discovering a
`#include` whose resolved path already matches an existing
`file_path_off`/`file_path_len` entry just reuses that entry's index in
`dep_pool` — it is never read, added to the table, or enqueued a second
time. No separate flag needed for this (unlike the earlier draft's
`visiting` field) — see "Resolution algorithm" for why cycle detection
no longer needs one either.

## Path resolution

Lexical, not filesystem-canonicalized — deliberately, to avoid needing
any additional syscall (`realpath`/`lstat`) beyond `sys_openat`/
`sys_read`/`sys_close` themselves: an included path is resolved by
taking the including file's own directory (everything up to its last
`/`, or empty for a bare top-level filename) and concatenating the
directive's own `path_text` onto it, then collapsing `./` and `dir/../`
segments through ordinary string manipulation. The result is used both
to open the file and as the file table's own identity key — the
"already known" lookup "Resolution algorithm" runs during discovery,
which is what makes include-once and (indirectly, via the resulting
graph) cycle detection possible.

**Known, accepted limitation**: two different lexical paths that happen
to reach the same file through a symlink are treated as two different
files (no re-inclusion protection between them) — the same limitation
many real-world `#pragma once`/include-guard systems have. Worth a
one-line note in the eventual user-facing docs, not worth the extra
syscalls to close for `v1.0.1`.

## Comment-awareness and the preamble boundary

This scan is **purely analytical** — unlike the earlier draft of this
design, it never writes bytes anywhere. A file's raw content already
sits, in full, in `source_pool` the instant it's read ("Resolution
algorithm" below); this pass just walks that already-stored span once,
left to right, to produce three things: `file_body_off[i]` (frozen the
moment the preamble ends), `file_body_line[i]` (a running newline count,
frozen at the same moment), and zero or more entries appended to
`dep_pool` (one per successfully parsed directive, each holding the
*resolved* target file's index — resolving and registering that target
in the file table, per "Resolution algorithm," happens right where a
directive is matched, below).

The scan can no longer treat "does this line start with `#`" as the
whole test, now that a directive doesn't have to sit at column 1
(the `;`-termination discussion, above) — it walks the bytes as a
small, four-state machine instead. One extra bit of state rides
alongside the four: `mut seen_body : bool := false;` — set the first
time `NORMAL` passes a byte that isn't whitespace (comments never set
it, per the state descriptions below).

- **NORMAL** — the default. On `/` followed by `/`, switch to
  `LINE_COMMENT`. On `/` followed by `*`, switch to `BLOCK_COMMENT`. On
  the literal byte sequence `#include` (not preceded or followed by an
  identifier character — `#` isn't a valid identifier character at all,
  so this is really just "on `#`", but spelled out for clarity): if
  `seen_body` is still `false`, switch to `IN_DIRECTIVE` (below); if
  `seen_body` is already `true`, this is exactly the case §6.2's
  preamble rule forbids — a dedicated diagnostic ("`#include` must
  appear before any other declaration in this file"), not a fall-through
  to `IN_DIRECTIVE` and not a silent pass-through either, since `#` has
  no other valid meaning anywhere in the grammar (§1.6) for this to
  degrade into. On any other non-whitespace byte: if `seen_body` was
  still `false`, this is the byte that ends the preamble — record
  `file_body_off[i]` and `file_body_line[i]` as they stand *right now*
  (this byte's own offset/line, not yet advanced past it) — then set
  `seen_body := true`; either way, advance past the byte, stay in
  `NORMAL`. On whitespace: advance past it, `seen_body` unchanged, stay
  in `NORMAL` (a newline here also advances the running line counter,
  same as in every other state).
- **LINE_COMMENT** — advance, unexamined, until a newline (which also
  advances the line counter), then return to `NORMAL`; `seen_body` is
  **not** touched by anything in this state, per §6.2's comment
  exemption. A `#include` sequence appearing here is ordinary comment
  text, never a directive — part of why this state machine has to exist
  at all, now that a directive can start anywhere `#` appears in real
  code, not just at column 1: without it, `// see #include "b.ptl";
  for an example` would misfire.
- **BLOCK_COMMENT** — advance, unexamined, until `*/` (newlines inside
  still counted), then return to `NORMAL`; `seen_body` untouched, same
  exemption. Same reasoning as `LINE_COMMENT`, for `/* ... */` spans,
  including ones a directive's own scan might otherwise straddle.
- **IN_DIRECTIVE** — entered the instant `#include` is matched in
  `NORMAL` while `seen_body` is still `false`. Requires, in order: at
  least one space, then `"` (anything else here — `<`, a bare character,
  nothing — is a diagnostic, per §6.2's reservation of `#include
  <path>`, never silently reinterpreted); then `path_text` up to the
  next `"` (this span is what "Resolution algorithm" resolves and
  registers, appending the resulting file-index to `dep_pool`); then
  optional whitespace; then a mandatory `;` (directive complete, return
  to `NORMAL`, `seen_body` still `false`). **The `;` must appear before
  any trailing comment**, exactly like a comment trailing any other
  statement (`mut x: int32 := 5; // note`, never `mut x: int32 := 5 //
  note\n;`) — a `//...`/`/* ... */` comment may still follow the `;` on
  the same line, handled by `NORMAL`'s own rules the moment control
  returns there, nothing `#include`-specific about it. Anything else
  encountered while `IN_DIRECTIVE` (a second `"` before whitespace/`;`,
  end of file, a byte that's neither whitespace nor `;` after the
  closing `"`) is a diagnostic.

`seen_body`, and the running line counter, both reset at the start of
scanning **every** file independently (the entry file and each included
file get their own) — the preamble rule is per file, per §6.2/§8.4, not
a property of the merged output. If a file's entire content is preamble
(comments and `#include`s only, nothing else) — a legal, if unusual,
"pure aggregator" file — `file_body_off[i]` ends up equal to that
file's own content length, i.e. an empty body span; nothing special
needed to handle this, "Resolution algorithm"'s emit phase just
contributes zero bytes for it.

This is a **bounded, special-purpose scanner**, not a step toward
`#include` joining the real token grammar (§6.2's own point) — it knows
exactly enough syntax to skip comments correctly, track one boolean,
and recognize one
directive shape, nothing about identifiers, other literals, or any other
construct.

## Resolution algorithm

**Why not in-place substitution.** The obvious algorithm — walk the
entry file, and the instant a `#include` is matched, recursively resolve
and splice the target's text in at that exact position — does not
reliably give the transitivity property above. Whether it happens to,
for any given file, depends on incidental details (how many sibling
`#include`s a file has, what sits between them) that are exactly the
kind of thing not worth reasoning about by hand, file by file. The
property needed — *every file's fully-resolved dependencies, and
nothing else, precede that file's own body, at every level of nesting*
— is a **topological-order** guarantee: for the dependency graph where
an edge points from a file to each of its own `#include` targets, the
final output must list every file's targets before the file itself.
That's not a byte-splicing problem, it's a graph-ordering one, so it
gets a graph-ordering algorithm (Kahn's algorithm — textbook, queue-
based, no recursion), not a smarter version of in-place substitution.

Three phases, each a plain loop over an explicit queue/worklist — no
function recursion anywhere, no inserting into the middle of an
already-written buffer (`source_pool`/`dep_pool` are only ever
*appended* to, and the final output buffer is only ever appended to as
well, once, in phase 3):

**Phase 1 — Discover** (queue of file-indices still needing to be
opened; starts holding just the entry file's index):

1. Dequeue a file-index `i`. Read its content into `source_pool`
   (`sys_openat`+`sys_read` in a loop to EOF+`sys_close`, mirroring
   `write_all`'s existing retry-loop shape), recording
   `file_content_off/len[i]`.
2. Run the comment-aware scan (above) over it once, producing
   `file_body_off[i]`/`file_body_line[i]`, and — for every directive
   found in its preamble, in order — resolving that directive's path
   (relative to *this* file's own directory) to a canonical string and
   looking it up in the file table:
   - **Already known** (matches an existing `file_path_off/len` entry,
     whether that entry has been dequeued/read yet or not): append its
     existing index to `dep_pool`. Nothing is re-read, re-scanned, or
     re-enqueued — this *is* include-once, with no separate flag.
   - **Not yet known**: allocate it the next file-index, record its
     resolved path in the table, append that new index to `dep_pool`,
     and enqueue it for its own turn at step 1.
3. Set `file_dep_start/count[i]` from what got appended to `dep_pool` in
   step 2, and `file_indegree[i] := file_dep_count[i]`.

Repeat until the queue is empty. Because a file is only ever enqueued
the *first* time its resolved path is seen (step 2's "already known"
branch never re-enqueues), this phase visits each distinct file exactly
once and always terminates — including when the inclusion graph has a
cycle, which this phase does **not** need to detect; that falls out for
free in phase 2.

**Phase 2 — Order** (Kahn's algorithm; a second, separate queue, this
one holding files whose remaining dependencies have all been resolved):

1. Enqueue every file-index `i` with `file_indegree[i] == 0` (files with
   no `#include`s of their own — the graph's leaves), in ascending
   index order (which is discovery order, from phase 1 — the natural,
   deterministic tie-break).
2. Dequeue a file-index `i`; append it to `order`. Then, for **every**
   other known file `j` whose `dep_pool[file_dep_start[j] ..
   file_dep_start[j]+file_dep_count[j])` range contains `i`: decrement
   `file_indegree[j]`; if it just reached 0, enqueue `j`. (A plain
   double loop over ≤64 files and ≤64 dependency-slots each — no
   separate reverse-adjacency structure needed at this scale; compare
   `AST_ARENA_SIZE`'s own "generous, not clever" sizing philosophy.)
3. Repeat until the queue is empty.

If `order_count` ends up less than the total number of known files,
whatever's left over (every file whose `file_indegree` never reached 0)
is, or depends on, a genuine cycle — diagnostic, naming those files
(§6.2/§8.4), stop. Otherwise `order` is a complete, valid topological
order: for every `#include` edge, the target's index appears before the
including file's index.

**Phase 3 — Emit**: walk `order` front to back; for each file-index
`i`, record a breakpoint (`out_pos` right now → file `i`, line
`file_body_line[i]`, see "Diagnostics under this model" below), then
append `source_pool[file_body_off[i] .. file_content_off[i]+
file_content_len[i])` — that file's own body span, verbatim, comments
inside it included — to the output buffer. The entry file, having
(transitively) everything else as a dependency, is always last;
everything ahead of it in `order` is, by construction, exactly its own
transitively-resolved dependencies, each already reduced to *only* its
own body content.

## Diagnostics under this model

Worth its own section — reordering content into topological order,
rather than substituting it in place, changes *how* a merged-buffer
offset maps back to a source file/line, and it's worth confirming this
mapping is still simple and correct, not just asserting it.

**It's actually simpler than the in-place design would have been, not
harder.** Under in-place substitution, a single file's own text could
end up scattered across the output in multiple, separately-positioned
pieces (its leading comments here, an included file's body there, more
of its own comments after that — the v1 reference's own §6.2 example,
with a header comment before its `#include`s and another comment
between two of them, is exactly this shape) — mapping an offset back to
"which of possibly several disjoint pieces of file X is this" is the
harder version of this problem. Under the topological model, **every known
file contributes exactly one contiguous span** to the output (its own
body, phase 3, nothing else, exactly once) — the same shape a
single-file compilation always had, just repeated ≤64 times instead of
once. `compute_line_col`'s existing single-file logic doesn't need
reinventing, only *retargeting*: given a merged offset `X`,

1. Find the breakpoint with the largest `out_pos ≤ X` (linear scan over
   `order_count` entries, each recorded during phase 3 — cheap at this
   scale, same "≤64, just scan it" choice phase 2's own indegree
   bookkeeping already makes) → that breakpoint's file-index `i` and
   `out_pos_i` are the file and the position, within the merged buffer,
   where *its* span began.
2. `X - out_pos_i` is `X`'s offset *within file `i`'s own body span* —
   count newlines from `0` to that local offset (exactly
   `compute_line_col`'s existing loop, unmodified) to get a *local* line
   number.
3. The real answer is `file_body_line[i] + local_line_number` (0-based
   local count, so the body's own first line adds 0) — `file_body_line`
   is exactly the piece existing single-file logic never needed, since a
   single file's body always started at its own line 1; here it doesn't,
   because the preamble (comments, `#include`s) that precede it in the
   *original* file were never copied into `source_pool`'s counted region
   at all (`file_body_off`/`file_body_line` are computed *after*
   skipping past them, "Comment-awareness" above) — so this offset is
   what corrects for "this body didn't start at line 1 of its own file."
   Column, on the last line found, is unaffected by any of this — same
   as always, offset minus the start of that line.

**Every diagnostic gains a filename** (`file_path_off/len[i]`, already
on hand from the lookup above) — something no Stage 1 message has ever
had to print before, single-file compilation being inherently
unambiguous about which file an error is in. This applies uniformly:
an error inside a spliced-in dependency's body reports *that*
dependency's own filename and *its own* local line number, never the
entry file's, regardless of how deep the inclusion chain that pulled it
in was, or where in `order` it ended up — exactly the transitivity
this whole design revision is about, now confirmed for diagnostics
specifically, not just for compiled output.

## Buffer sizing

**Two buffers now, not one** — a consequence of phase 1 reading every
known file's full content up front (into `source_pool`) before phase 3
ever decides the final order and copies bodies out of it into the
actual output buffer; the two can't share storage, since a file's
`source_pool` span has to stay valid until phase 3 reads from it, by
which point later files may already have been appended after it. The
proof of concept's own single buffer is small — `lexer.ptl`'s `src_buf
: uint8[65536]` (64 KiB), sized for one hand-written test file — and
neither `source_pool` nor the final output buffer should stay that
size: both need real headroom for `v1.0.6`'s own multi-file source once
that rewrite happens. Size both in line with Hoare's own `SRC_BUF_SIZE`
precedent (1 MiB, `Hoare/src/config.inc`) — cheap, `.bss`-only cost,
same reasoning already used for `AST_ARENA_SIZE` this session — noting
that `source_pool` holding ≤64 files' *full* content (comments and all)
while the output buffer holds only their *body* spans means
`source_pool` is the one actually worth being generous with; the output
buffer is bounded above by `source_pool`'s own size regardless (it can
never hold more than what `source_pool` contributed to it).

## Testing plan

New fixtures, each run through all three of `lexer`/`parser`/`codegen`
(the whole pipeline needs to agree, since all three gain this pass):

1. **Plain single include** — one file includes one other; merged
   output/AST/codegen matches the hand-spliced equivalent single file.
2. **Nested chain, correct order and correct diagnostics** — `A`
   includes `B` includes `C` (each with no other siblings); final
   output order is `C`'s body, then `B`'s, then `A`'s (per "Resolution
   algorithm" — the deepest dependency first, the entry file last), and
   a deliberate syntax error planted in `C` reports `C`'s filename and
   `C`'s **own** local line number (not a merged-buffer-relative one,
   not `A`'s), confirming "Diagnostics under this model."
3. **Diamond** — `A` includes both `B` and `C`, and both `B` and `C`
   include `D`; `D`'s body appears **exactly once** in the output,
   positioned before *both* `B`'s and `C`'s bodies (which are both
   positioned before `A`'s) — the direct test of Kahn's-algorithm
   ordering over a non-linear graph, not just a chain.
4. **Cycle** — `A` includes `B` includes `A`; phase 1 (discovery)
   terminates normally (each of `A`/`B` only ever gets read once), and
   phase 2 (ordering) reports a clean diagnostic naming the files stuck
   at nonzero `file_indegree` — not a hang, not a stack overflow, and
   not a silent, incomplete `order`.
5. **Relative path correctness** — nested directories (`src/main.ptl`
   including `src/util/helpers.ptl`, which itself includes `../
   shared/types.ptl`) resolve against *each file's own* directory, not
   the entry file's or the process's cwd.
6. **Regression**: the full existing single-file fixture suite (Hoare's
   `cases`/`codegen_cases`/`checker_cases`/`blackbox_cases`, this
   session's own multi-function suite) still passes unchanged — a
   program with zero `#include` lines must behave identically to today,
   byte-for-byte.
7. **Reserved/invalid forms rejected cleanly** — `#include b.ptl` (no
   quotes) and `#include <b.ptl>` (the reserved angle-bracket form) each
   produce a clear diagnostic, not a misparse or a silent no-op.
8. **Trailing comment after `;`** — `#include "./b.ptl"; // shared
   types` is accepted; `#include "./b.ptl" extra;` (anything other than
   whitespace between the closing `"` and the `;`) is rejected.
9. **Directives don't need their own line** — `#include "./a.ptl";
   #include "./b.ptl"; function main() : void { ... }` all on one
   physical line splices both files and parses the function correctly —
   the direct test of why `;`-termination replaced newline-termination.
10. **Comment text is never misread as a directive** — a line comment
    (`// see #include "evil.ptl"; below`) or a block comment spanning
    one (`/* #include "evil.ptl"; */`) containing something that looks
    like a directive does **not** trigger a splice; `evil.ptl` is never
    opened, and the comment's own text is copied through unchanged.
11. **Leading comments before the preamble's includes are fine** — a
    file comment, then one or more `#include`s (with comments freely
    between them too), then real code: parses exactly as if the leading
    comments weren't there.
12. **An include after real code is rejected** — a `function`/`struct`/
    `extern function` declaration followed later in the same file by a
    `#include` produces the dedicated preamble-position diagnostic
    (§6.2/§8.4), not a generic parse error and not a silent splice.
13. **The preamble rule is per file, not global** — `A`'s own preamble
    contains `#include "B.ptl";`, and `B` itself opens with its own
    leading comment and its own `#include "C.ptl";` before `B`'s first
    real declaration: this is valid — `B`'s preamble is checked against
    `B`'s own content, independently of where `A`'s `#include "B.ptl";`
    happens to sit within `A`. (`A` including `B` from a position that
    violates *`A`'s own* preamble rule is still rejected, per fixture
    12 — this fixture is specifically about `B`'s independence from
    `A`, not an exception to fixture 12.)
14. **Transitivity holds at 3+ levels with siblings mixed in** — `A`
    includes `B` and `E` (in that order); `B` includes `C` and `D`;
    none of `C`/`D`/`E` include anything further. Every one of `C`'s,
    `D`'s, and `E`'s bodies must appear before `B`'s; `B`'s (and `E`'s)
    before `A`'s — checked directly against the produced `order`, not
    just "the program still compiles," since a bug that reorders two
    unrelated leaves relative to each other wouldn't otherwise be
    caught by a looser check.
15. **A deeply-nested diagnostic is unaffected by its position in
    `order`** — same shape as fixture 2, but with the error planted in
    the *first-discovered, last-emitted* file (the entry file's own
    body) instead of the *last-discovered, first-emitted* one (a leaf):
    confirms the offset→file/line mapping ("Diagnostics under this
    model") doesn't secretly depend on discovery order versus emission
    order lining up in some particular way.

## What this step deliberately does not touch

No macro expansion, no conditional compilation (`#include` stays the
only preprocessor directive, per §6.2) — and no attempt yet at reusing
a previously-compiled unit's *output* (that's `v1.0.4`, true separate
compilation, once the LLVM backend exists). `v1.0.1`'s "Resolution
algorithm" reorders and concatenates each file's *own already-read
source text* into one buffer — every file is still parsed, checked, and
code-generated together as one `program`, in one pass (§6.2's own
"textual splicing, not separate compilation" point still holds); only
the *positioning* of that text within the merged buffer is no longer a
literal, in-place substitution. `sys_openat`/`sys_close` are added
*only* for `#include`'s own needs here — no general file-I/O standard-
library work rides along with this step.
