FROM ubuntu:24.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends nasm binutils bash diffutils llvm \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace
COPY . /workspace

RUN chmod +x hoare scripts/build.sh scripts/run_tests.sh scripts/run_parser_tests.sh scripts/run_blackbox_tests.sh scripts/run_checker_tests.sh scripts/run_codegen_tests.sh scripts/run_stack_check_tests.sh scripts/run_hoare_cli_tests.sh
RUN scripts/build.sh
RUN scripts/run_tests.sh
RUN scripts/run_parser_tests.sh
RUN scripts/run_blackbox_tests.sh
RUN scripts/run_checker_tests.sh
RUN scripts/run_codegen_tests.sh
RUN scripts/run_stack_check_tests.sh
RUN scripts/run_hoare_cli_tests.sh

ENTRYPOINT ["/workspace/build/lexer"]
