# Edsger's own test/dev image. Self-contained: the Stage-0 `hoare`
# toolchain it needs is vendored in as an already-built binary
# (`vendor/hoare/`, `hoare` CLI script + `build/codegen`, extracted from
# a verified `postulate-hoare-release` build -- see docs/postulate_
# stage1_bootstrap_plan.md for why Edsger needs Hoare at all: it's the
# Stage-0 compiler that bootstraps Stage 1), not rebuilt from Hoare's
# own source on every image build. Edsger's own source and tests are
# still deliberately NOT baked in here (see docker-compose.yml's own
# volume mount instead), so editing a .ptl file or a test fixture never
# requires rebuilding this image at all.
#
# Build context is this directory itself now (no sibling directory
# reached into):
#
#   docker build -f Edsger_v0/Dockerfile -t postulate-edsger Edsger_v0
#
# or, equivalently, via docker-compose.yml (see its own `edsger-dev`
# service, already wired to this file).
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends nasm binutils bash diffutils llvm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY ./vendor/hoare /workspace

RUN chmod +x hoare build/codegen

ENV PATH="/workspace:${PATH}"

WORKDIR /workspace/Edsger
ENTRYPOINT ["/bin/bash"]
