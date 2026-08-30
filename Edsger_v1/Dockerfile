# Edsger v1.1.n's own test/dev image. Self-contained: the Stage-0/
# Stage-1-bootstrap toolchain it needs is vendored in as an already-
# built binary (`vendor/codegen_selfhost/`, extracted from a verified
# Edsger_v0 build -- see build.sh's own header comment for exactly what
# this binary is and why it's needed), not rebuilt from Hoare's or
# Edsger_v0's own source on every image build. This is also why this
# image needs no `nasm`/Hoare at all, unlike Edsger_v0's own dev image
# -- codegen_selfhost is already a built ELF binary, there is nothing
# left to assemble.
#
# Edsger v1.1.n's own source and tests are still deliberately NOT baked
# in here (see docker-compose.yml-style volume mounting instead, if
# ever added), so editing a .ptl file or a test fixture never requires
# rebuilding this image at all.
#
# Build context is this directory itself, self-contained:
#
#   docker build -f Edsger_v1/Dockerfile -t postulate-edsger-v1 Edsger_v1
FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends binutils bash diffutils llvm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY ./vendor/codegen_selfhost /workspace

RUN chmod +x codegen_selfhost

ENV PATH="/workspace:${PATH}"

WORKDIR /workspace/Edsger
ENTRYPOINT ["/bin/bash"]
