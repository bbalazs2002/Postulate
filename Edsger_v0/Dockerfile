# Edsger's own test/dev image. Builds Hoare (Stage 0) once, at image-
# build time, so every container started from this image already has a
# working `hoare` CLI ready to use -- Edsger's own source and tests are
# deliberately NOT baked in here (see docker-compose.yml's own volume
# mount instead), so editing a .ptl file or a test fixture under
# Edsger/ never requires rebuilding this image; only a change to
# Hoare's own source does.
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

RUN chmod +x hoare scripts/build.sh
RUN ./scripts/build.sh

ENV PATH="/workspace:${PATH}"

WORKDIR /workspace/Edsger
ENTRYPOINT ["/bin/bash"]
