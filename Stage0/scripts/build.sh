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
nasm -f elf64 -I src/ -o build/stmt_parser.o src/stmt_parser.asm
nasm -f elf64 -I src/ -o build/top_parser.o src/top_parser.asm
nasm -f elf64 -I src/ -o build/ast_dump.o src/ast_dump.asm

ld -static -no-pie -e _start -o build/parser \
    build/parser_main.o build/lexer.o build/runtime.o build/ast.o \
    build/parser_tokens.o build/type_parser.o build/expr_parser.o \
    build/stmt_parser.o build/top_parser.o build/ast_dump.o

# --- semantic checker binary (name resolution + core type checking --
# see docs/postulate_stage0_semantics_spec.md) ---
nasm -f elf64 -I src/ -o build/checker_main.o src/checker_main.asm
nasm -f elf64 -I src/ -o build/symtab.o src/symtab.asm
nasm -f elf64 -I src/ -o build/sema_types.o src/sema_types.asm
nasm -f elf64 -I src/ -o build/sema_expr.o src/sema_expr.asm
nasm -f elf64 -I src/ -o build/sema_stmt.o src/sema_stmt.asm

ld -static -no-pie -e _start -o build/checker \
    build/checker_main.o build/lexer.o build/runtime.o build/ast.o \
    build/parser_tokens.o build/type_parser.o build/expr_parser.o \
    build/stmt_parser.o build/top_parser.o \
    build/symtab.o build/sema_types.o build/sema_expr.o build/sema_stmt.o

# --- code generator binary (NASM text codegen, Phase 1 -- see
# docs/postulate_stage0_codegen_spec.md) ---
nasm -f elf64 -I src/ -o build/codegen_main.o src/codegen_main.asm
nasm -f elf64 -I src/ -o build/codegen_types.o src/codegen_types.asm
nasm -f elf64 -I src/ -o build/codegen_expr.o src/codegen_expr.asm
nasm -f elf64 -I src/ -o build/codegen_stmt.o src/codegen_stmt.asm
nasm -f elf64 -I src/ -o build/codegen_program.o src/codegen_program.asm

ld -static -no-pie -e _start -o build/codegen \
    build/codegen_main.o build/lexer.o build/runtime.o build/ast.o \
    build/parser_tokens.o build/type_parser.o build/expr_parser.o \
    build/stmt_parser.o build/top_parser.o \
    build/symtab.o build/sema_types.o build/sema_expr.o build/sema_stmt.o \
    build/codegen_types.o build/codegen_expr.o build/codegen_stmt.o \
    build/codegen_program.o
