#!/usr/bin/env bash
# Builds Edsger's own compiler binary, `build/codegen`, from source.
#
# Two-stage bootstrap, as of the modular/dynamic-memory rewrite (docs/
# postulate_stage1_bootstrap_plan.md's "Modular, dynamic-memory Edsger"
# section):
#
#   1. `hoare` compiles `src/codegen_selfhost.ptl` -- a throwaway,
#      capacity-bumped, single-file v0 copy of the OLD architecture
#      (`src/codegen.ptl`, still untouched, still the historical
#      record) -- into `build/codegen_selfhost`. This binary exists
#      for exactly one purpose: it's the only thing that can read a
#      source file as large as Edsger's own real, modular source
#      without hitting the original architecture's fixed-capacity
#      limits (the 2026-08-28 self-hosting dry run). It needs a raised
#      stack limit to run at all (`ulimit -s`, below) -- its own
#      buffers are still fixed-size stack locals, just much bigger
#      ones. Nothing outside this script ever calls it directly.
#   2. `build/codegen_selfhost` compiles Edsger's REAL source --
#      `src/modular/`, genuine `namespace`/`use` files, genuinely
#      dynamic (`sys_mmap`/`sys_mremap`-backed, growable) memory, no
#      capacity ceiling of its own -- and the result is assembled
#      (`llc`) and linked (`ld`) into the actual `build/codegen`
#      binary used from here on by `edsger`/the test runners. This
#      binary needs no raised stack limit to run (the entire point of
#      the rewrite) -- confirmed by the full fixture suite passing
#      against it with the default 8 MiB stack.
#
# Namespace resolution for step 2 is relative to the compiler process's
# own CWD (postulate_v1_language_reference.md SS6.2b's default 1:1
# rule) -- `codegen_selfhost` is therefore invoked with CWD set to
# `src/modular/` so `\Edsger\Lexer` etc. resolve to `Edsger/Lexer.ptl`
# alongside it; `main.ptl` (the `\Main` file) is still fed on stdin,
# exactly like every other Edsger invocation.
#
# Requires `hoare`, `llc`, and `ld` on PATH (the Edsger dev image
# already provides all three, `hoare` vendored in as an already-built
# binary -- see ../Dockerfile).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

# Stage 1: the throwaway bootstrap compiler.
hoare src/codegen_selfhost.ptl -o build/codegen_selfhost

# Stage 2: the real, modular compiler, built by stage 1.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

(
  cd src/modular
  ulimit -s 262144
  "$OLDPWD/build/codegen_selfhost" < main.ptl
) > "$workdir/edsger.ll"

llc -filetype=obj -mtriple=x86_64-unknown-linux-gnu -o "$workdir/edsger.o" "$workdir/edsger.ll"
ld -static -no-pie -e _start -o build/codegen "$workdir/edsger.o"
