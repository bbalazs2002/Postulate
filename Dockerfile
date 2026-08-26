FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends nasm binutils bash diffutils llvm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY ./Hoare /workspace

RUN chmod +x hoare scripts/build.sh
RUN ./scripts/build.sh

ENTRYPOINT ["/workspace/build/lexer"]
