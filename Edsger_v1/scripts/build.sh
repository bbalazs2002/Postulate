#!/usr/bin/env bash
# Builds Edsger v1.1.n's own compiler binary, `build/codegen`, from its
# real, modular source.
#
# A SINGLE stage now, unlike Edsger_v0's own two-stage bootstrap
# (`hoare` compiles `codegen_selfhost.ptl`, then `codegen_selfhost`
# compiles the real source): `codegen_selfhost` itself is vendored here
# as an already-built binary (`vendor/codegen_selfhost/`, extracted
# once from a verified Edsger_v0 build and put on `PATH` by ../Dockerfile
# -- see that file's own header comment), not rebuilt from Hoare's or
# Edsger_v0's own source on every image build. This is safe because
# `codegen_selfhost.ptl` (the throwaway, capacity-bumped, single-file
# bootstrap it was built from) is itself untouched by the v1.1.n
# rewrite -- only the REAL modular source this stage compiles has
# changed.
#
# `codegen_selfhost`'s only job is reading `src/modular/`'s own files
# without hitting the ORIGINAL single-file architecture's fixed-
# capacity limits (the 2026-08-28 self-hosting dry run, docs/postulate_
# stage1_bootstrap_plan.md) -- it needs a raised stack limit to run at
# all (`ulimit -s`, below); its own buffers are still fixed-size stack
# locals, just much bigger ones. The resulting `build/codegen` needs no
# raised stack limit itself (the whole point of the modular/dynamic-
# memory rewrite) -- confirmed by the full fixture suite passing
# against it with the default 8 MiB stack.
#
# Namespace resolution is relative to the compiler process's own CWD
# (postulate_v1_language_reference.md SS6.2b's default 1:1 rule) --
# `codegen_selfhost` is therefore invoked with CWD set to `src/modular/`
# so `\Edsger\Lexer` etc. resolve to `Edsger/Lexer.ptl` alongside it;
# `main.ptl` (the `\Main` file) is still fed on stdin, exactly like
# every other Edsger invocation.
#
# Requires `llc` and `ld` on PATH (the Edsger v1.1.n dev image already
# provides both -- see ../Dockerfile).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

(
  cd src/modular
  ulimit -s 262144
  codegen_selfhost < main.ptl
) > "$workdir/edsger.ll"

llc -filetype=obj -mtriple=x86_64-unknown-linux-gnu -o "$workdir/edsger.o" "$workdir/edsger.ll"
ld -static -no-pie -e _start -o build/codegen "$workdir/edsger.o"
