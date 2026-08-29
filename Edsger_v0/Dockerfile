# Edsger's own test/dev image. Needs a working `hoare` CLI ready before
# Edsger's own source and tests are ever touched (see docker-compose.
# yml's own volume mount instead of baking those in here) -- editing a
# .ptl file or a test fixture under Edsger_v0/ never requires rebuilding
# this image.
#
# This is the edsger-release branch: `./Hoare` here is just the
# **finished, already-built** Hoare compiler (the `hoare` wrapper
# script + its `build/codegen` binary, both checked in directly) rather
# than Hoare's full source tree -- Edsger's own two-stage bootstrap
# genuinely needs a working `hoare` to compile itself with, but not
# Hoare's source, tests, or its own Docker/release tooling, none of
# which belongs in a release meant to be just Edsger's own source. See
# the main Postulate repository's Hoare/ directory for how these two
# files are actually built from source.
#
# nasm/binutils stay installed below because `hoare` itself calls out
# to them (nasm/ld) at runtime to compile whatever it's given, `build/
# codegen` included -- it's not just a build-time dependency of Hoare's
# own source.
#
# Build context must be the repository root (this Dockerfile reaches
# ./Hoare, a sibling of Edsger_v0/, not something inside Edsger_v0/
# itself):
#
#   docker build -f Edsger_v0/Dockerfile -t postulate-edsger .
#
# or, equivalently, via docker-compose.yml (see its own `edsger-dev`
# service, already wired to this file).
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends nasm binutils bash diffutils llvm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY ./Hoare /workspace

RUN chmod +x hoare build/codegen

ENV PATH="/workspace:${PATH}"

WORKDIR /workspace/Edsger
ENTRYPOINT ["/bin/bash"]
