#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build

nasm -f elf64 -I src/ -o build/main.o src/main.asm
nasm -f elf64 -I src/ -o build/lexer.o src/lexer.asm

ld -static -no-pie -e _start -o build/lexer build/main.o build/lexer.o
