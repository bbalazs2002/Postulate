#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

nasm -f elf64 -I src/ -o build/main.o src/main.asm
nasm -f elf64 -I src/ -o build/lexer.o src/lexer.asm
nasm -f elf64 -I src/ -o build/runtime.o src/runtime.asm

ld -static -no-pie -e _start -o build/lexer build/main.o build/lexer.o build/runtime.o

# --- parser binary (type/expr slice -- see docs/postulate_stage0_parser_spec.md) ---
nasm -f elf64 -I src/ -o build/parser_main.o src/parser_main.asm
nasm -f elf64 -I src/ -o build/ast.o src/ast.asm
nasm -f elf64 -I src/ -o build/parser_tokens.o src/parser_tokens.asm
nasm -f elf64 -I src/ -o build/type_parser.o src/type_parser.asm
nasm -f elf64 -I src/ -o build/expr_parser.o src/expr_parser.asm
nasm -f elf64 -I src/ -o build/ast_dump.o src/ast_dump.asm

ld -static -no-pie -e _start -o build/parser \
    build/parser_main.o build/lexer.o build/runtime.o build/ast.o \
    build/parser_tokens.o build/type_parser.o build/expr_parser.o build/ast_dump.o
