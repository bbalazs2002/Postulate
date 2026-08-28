# Edsger — the Postulate Stage 1 compiler

Named in honor of Edsger Wybe Dijkstra. Edsger compiles
[Postulate v1.0](../docs/postulate_v1_0_language_reference.md)
— v0 plus namespaces/`use`, `char`, `as`, pointer arithmetic, `*void`,
`uintptr`, `sizeof`/`lengthof`, and the twelve-syscall `extern function`
whitelist — into real, linked, runnable ELF binaries. It is itself
written in Postulate and compiles itself: `src/modular/` is Edsger's
own real source (genuine `namespace`/`use` files, dynamically-allocated
memory), and `scripts/build.sh` builds it using nothing but `hoare`
(Stage 0), `llc`, and `ld`.

**If you just want to compile a `.ptl` file and don't care how Edsger
itself is built, skip to "Release image" below.**

## Layout

```
edsger                     the compiler CLI (see "Compiling a program")
Dockerfile                  dev/test image
Dockerfile.release           release image (see "Release image")
scripts/build.sh              two-stage bootstrap (see below)
src/modular/                  Edsger's own real source — start here to read/modify Edsger
  main.ptl                      \Main -- entry point, driver, error reporting
  Edsger/Dynamic.ptl             sys_mmap/sys_mremap-backed growable buffers
  Edsger/Lexer.ptl                tokenizer
  Edsger/Parser.ptl                 recursive-descent parser + AST
  Edsger/Sema.ptl                     name/type resolution, namespace & file discovery
  Edsger/Codegen.ptl                    LLVM IR emission, extern/syscall wrappers, `_start`
src/codegen.ptl              the ORIGINAL single-file architecture — historical, unbuilt by
                              default, kept for reference (see below)
src/codegen_selfhost.ptl     a throwaway bootstrap tool (stage 1 of build.sh) — not a source
                              to develop against
src/lexer.ptl, lexer1.ptl,
  lexer2.ptl, parser.ptl,
  sema.ptl                   earlier, independently-tested milestone snapshots from Edsger's
                              own incremental construction — each still has its own test suite
                              below, none of them are imported by anything
tests/                      fixtures for every module above (lexer/parser/sema/codegen_cases)
```

## Why two source trees

Edsger was originally built as one self-contained file
(`src/codegen.ptl`) because v0 (which compiled it, via `hoare`) has no
`#include`/module system — every stage of the bootstrap had to embed a
full copy of everything before it. Once Edsger itself could parse real
`namespace`/`use`, its source was split for real: `src/modular/` is
that split, real-module version, using genuinely growable
(`sys_mmap`/`sys_mremap`-backed) memory instead of the original's
fixed-size buffers. **`src/modular/` is what actually gets built and
shipped** — `src/codegen.ptl` stays on disk, untouched, as the
historical single-file record of how Edsger got here, not because
anyone should build against it. See
`../docs/postulate_stage1_bootstrap_plan.md` for the full history if
you're curious.

## Build and test

```powershell
docker build -t postulate-edsger Edsger_v0
```

(Build context is the **repository root** — this Dockerfile reaches
`../Hoare`, a sibling directory, not something inside `Edsger_v0/`.)

This assembles Hoare inside the image (`Edsger_v0/Dockerfile`'s own
job), then — from inside a container built from that image — running
`scripts/build.sh` does Edsger's own **two-stage bootstrap**:

1. `hoare` compiles `src/codegen_selfhost.ptl` (a throwaway,
   capacity-bumped copy of the original single-file architecture) into
   `build/codegen_selfhost`. Its only job is reading `src/modular/`'s
   own files without hitting the original architecture's fixed-capacity
   limits — nothing outside `build.sh` ever calls it directly, and it
   needs a raised stack limit (`ulimit -s`, already handled inside the
   script) to run at all.
2. `build/codegen_selfhost` compiles `src/modular/main.ptl` (real
   `namespace`/`use`, real dynamic memory, no capacity ceiling of its
   own) — the result is assembled (`llc`) and linked (`ld`) into the
   real `build/codegen`, the binary `edsger` and every test runner
   actually use. It needs **no** raised stack limit to run.

Then run the fixture suites (each module independently):

```bash
Edsger_v0/tests/run_all_tests.sh
```

- `run_lexer_tests.sh` / `run_parser_tests.sh` / `run_sema_tests.sh` —
  exercise the earlier milestone snapshots (`src/lexer.ptl`,
  `src/parser.ptl`, `src/sema.ptl`), each built fresh from source by
  its own runner.
- `run_codegen_tests.sh` — builds the original `src/codegen.ptl`
  directly (not `src/modular/`) and checks its emitted LLVM IR text
  against `tests/codegen_cases/*.expected.stdout` — a regression gate
  on the historical single-file architecture, kept green as a record
  that it still behaves identically to before the split.

The same `codegen_cases/` fixtures also pass against the real,
released `build/codegen` (the whole point of the split/rewrite) —
verified directly, not through a dedicated script, by piping each
`*.ptl` fixture through `build/codegen` and diffing the result the same
way.

## Compiling a program

`./edsger` is the single command that replaces the manual pipeline
(`build/codegen` → `llc` → `ld`) end to end:

```bash
./edsger test.ptl              # -> ./test
./test
```

```
usage: edsger <file.ptl> [-o <output>] [--emit-llvm | -c]
  -o <output>     output path (default: <file> with .ptl stripped)
  --emit-llvm     stop after codegen, write the raw LLVM IR text (output defaults to .ll)
  -c              stop after assembling to a native object file, don't link (output defaults to .o)
```

Needs `llc`/`ld` on `PATH` and `build/codegen` already built. **Multi-
file programs**: namespace resolution is relative to the compiler
process's own current working directory (see the
[v1.0 reference](../docs/postulate_v1_0_language_reference.md) §6.3) —
run `edsger` from the root of your own namespace tree, with the entry
(`\Main`) file's path given relative to that same root:

```bash
cd my_project/src   # \Foo\Bar resolves to ./Foo/Bar.ptl from here
../../Edsger_v0/edsger main.ptl -o ../build/myprogram
```

**`edsger`'s own exit codes** (before/after the underlying
`build/codegen`/`llc`/`ld` run):

| Code | Meaning |
|---|---|
| `5` | `llc` rejected the generated LLVM IR — an internal Edsger bug, not a problem with your input. |
| `6` | `ld` failed to link — usually a missing `main` (a library-only `.ptl` with no `main` should be compiled with `-c` instead). |
| `64` | Usage error (missing/nonexistent input, bad flag, both `--emit-llvm` and `-c` given). |

Any other exit code is `build/codegen`'s own:

| Code | Meaning |
|---|---|
| `0` | Success — LLVM IR written to stdout. |
| `1` | Lexical or parse error (`sema error: parse error ...` / `lex error: ...` on stderr). |
| `2` | Semantic error, or the compiled program couldn't be fully written out. |

## Release image

`Dockerfile.release` packages just the compiler and what `edsger` needs
to run it — `build/codegen`, the `edsger` script, `llvm`/`binutils`/
`bash`, and the [v1.0 language reference](../docs/postulate_v1_0_language_reference.md)
— for anyone who wants to compile Postulate v1.0 programs without
building Edsger (or Hoare, which it no longer needs at runtime) from
source. Built `FROM` the already-tested dev image, so a release is
always exactly what the dev image's own build just produced.

Build from the **repository root**:

```powershell
docker build -t postulate-edsger Edsger_v0
docker build -f Edsger_v0/Dockerfile.release -t postulate-edsger-release .
```

Use — `edsger` is the image's `ENTRYPOINT`, `WORKDIR` is `/work`:

```powershell
docker run --rm -v ${PWD}:/work postulate-edsger-release test.ptl
```

For a multi-file program, mount your whole namespace-tree root and pass
the entry file's path relative to it (`edsger`'s own CWD inside the
container is `/work`):

```powershell
docker run --rm -v ${PWD}/my_project/src:/work postulate-edsger-release main.ptl -o /work/out/myprogram
```

**Windows-host bind-mount note**: same caveat as Hoare's own release
image (see [../Hoare/README.md](../Hoare/README.md)) — Docker Desktop
bind mounts don't always reflect a container-side `chmod +x` back onto
NTFS; run the compiled binary from inside the container if it won't
execute directly on the host.

The language reference lives inside the image at
`/opt/edsger/docs/postulate_v1_0_language_reference.md`; pull a local
copy with:

```powershell
docker run --rm --entrypoint cat postulate-edsger-release /opt/edsger/docs/postulate_v1_0_language_reference.md > language_reference.md
```

## Published releases

The version number here tracks Edsger **the tool**'s own release
maturity, not the Postulate v1.0 language it compiles — `v0.1.0`
reflects that Edsger itself is still early: recently self-hosted, with
real, known gaps against its own target language (§8 of the
[v1.0 reference](../docs/postulate_v1_0_language_reference.md)).

Pushing an `edsger-vX.Y.Z` tag runs `.github/workflows/release-edsger.yml`:
builds and tests the dev image, builds and tests the release image
(the two-stage bootstrap above, plus the fixture suite run directly
against the resulting `build/codegen`), and publishes it two ways:

- **The release image itself**, pushed to
  `ghcr.io/<owner>/postulate-edsger:vX.Y.Z` (and `:latest`) — use
  exactly like the locally-built release image above, just with that
  image name instead of `postulate-edsger-release`.
- **A self-contained tarball** (`scripts/bundle_release.sh`), attached
  to the GitHub Release itself, for anyone who'd rather not use Docker
  at all: extract it and run `./edsger test.ptl` directly. It bundles
  `llc`/`ld` and their own shared-library dependencies (`ldd`-resolved
  against the exact Ubuntu 24.04 build the Docker image itself uses),
  so nothing needs separately installing on the target machine — a
  best-effort portability measure (works on essentially any
  actively-maintained x86-64 Linux distribution) rather than the same
  hermetic guarantee the Docker image gives; see the script's own
  header comment (and `Hoare/scripts/bundle_release.sh`'s, which it
  mirrors) for the full reasoning.

## Language

See [docs/postulate_v1_0_language_reference.md](../docs/postulate_v1_0_language_reference.md)
for exactly what this compiler accepts — including, importantly, its
own §8, listing the real v1 design's features this compiler doesn't
implement yet (statement sugar, floats, contracts, `ref` params,
operator overloading, and a few others). Don't write against
[the full v1 design reference](../docs/postulate_v1_language_reference.md)
directly and expect it all to compile.
