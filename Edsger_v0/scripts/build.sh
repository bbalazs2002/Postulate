#!/usr/bin/env bash
# Builds Edsger's own compiler binary, `build/codegen`, from source --
# the Edsger analogue of Hoare/scripts/build.sh. Much shorter than that
# one: Hoare links several separately-assembled NASM objects together,
# but Edsger's own copy-and-extend architecture means `src/codegen.ptl`
# is already the WHOLE compiler in one self-contained file (it embeds
# its own copies of the lexer/parser/semantic-analyzer stages ahead of
# it -- see codegen.ptl's own header comment) -- one `hoare` invocation
# is the entire build.
#
# Requires `hoare` on PATH (or the Edsger dev image, which already
# builds and PATHs it -- see ../Dockerfile) -- Edsger is itself written
# in Postulate v0, compiled by Hoare (Stage 0), exactly like every
# other `.ptl` file in this repository.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

hoare src/codegen.ptl -o build/codegen
