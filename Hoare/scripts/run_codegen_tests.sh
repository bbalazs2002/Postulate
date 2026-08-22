#!/usr/bin/env bash
# Runs every fixture under tests/codegen_cases/*.ptl through the FULL
# pipeline: build/codegen -> .asm text -> nasm -> ld -> execute the
# resulting binary -> compare its real exit code (and stdout, for the
# sys_write cases) against the checked-in .expected.*. A qualitatively
# different verification than every earlier suite's static-text diff --
# see docs/postulate_stage0_codegen_spec.md's "Testing" section.
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

fail=0
count=0
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

for src in tests/codegen_cases/*.ptl; do
    count=$((count + 1))
    name=$(basename "$src" .ptl)
    base="tests/codegen_cases/$name"

    ./build/codegen < "$src" > "$workdir/$name.asm" 2>"$workdir/$name.codegen_err"
    codegen_code=$?

    if [[ -f "${base}.expected.codegen_exit" ]]; then
        expected_codegen_code=$(cat "${base}.expected.codegen_exit")
        if [[ "$codegen_code" != "$expected_codegen_code" ]]; then
            echo "FAIL (codegen exit $codegen_code != $expected_codegen_code): $name"
            fail=1
        fi
        if [[ -f "${base}.expected.codegen_stderr" ]] && \
           ! diff -u "${base}.expected.codegen_stderr" "$workdir/$name.codegen_err"; then
            echo "FAIL (codegen stderr): $name"
            fail=1
        fi
        continue
    fi

    if [[ "$codegen_code" != 0 ]]; then
        echo "FAIL (codegen exit $codegen_code != 0): $name"
        cat "$workdir/$name.codegen_err"
        fail=1
        continue
    fi

    if ! nasm -f elf64 -o "$workdir/$name.o" "$workdir/$name.asm" 2>"$workdir/$name.nasm_err"; then
        echo "FAIL (nasm assemble): $name"
        cat "$workdir/$name.nasm_err"
        fail=1
        continue
    fi

    if ! ld -static -no-pie -e _start -o "$workdir/$name.bin" "$workdir/$name.o" 2>"$workdir/$name.ld_err"; then
        echo "FAIL (ld link): $name"
        cat "$workdir/$name.ld_err"
        fail=1
        continue
    fi

    "$workdir/$name.bin" > "$workdir/$name.stdout" 2>"$workdir/$name.stderr"
    actual_exit=$?

    expected_exit=$(cat "${base}.expected.exit")
    if [[ "$actual_exit" != "$expected_exit" ]]; then
        echo "FAIL (exit $actual_exit != $expected_exit): $name"
        fail=1
    fi

    if [[ -f "${base}.expected.stdout" ]] && \
       ! diff -u "${base}.expected.stdout" "$workdir/$name.stdout"; then
        echo "FAIL (stdout): $name"
        fail=1
    fi
done

echo "Ran $count fixture(s)."
exit $fail
