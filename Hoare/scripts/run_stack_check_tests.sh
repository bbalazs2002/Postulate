#!/usr/bin/env bash
# Runs the debug-only stack-corruption instrumentation (POSTULATE_STACK_
# CHECK=1, see codegen_main.asm/codegen_program.asm) two ways:
#
# 1. tests/stack_check_cases/*.asm -- hand-written NASM, assembled/linked/
#    executed directly (no build/codegen involved). Postulate source has
#    no way to deliberately corrupt the stack (no unsafe escape hatch),
#    so proving the detector itself fires requires directly-authored
#    broken assembly matching the instrumented shape byte-for-byte, each
#    with exactly one injected bug isolating one of the two checks.
#
# 2. Every tests/codegen_cases/*.ptl fixture that normally compiles and
#    runs (i.e. has no .expected.codegen_exit -- those fail before any
#    instrumentation-relevant code is even emitted) is recompiled with
#    the flag on, assembled, linked, and executed again, asserting the
#    *same* expected exit code/stdout as scripts/run_codegen_tests.sh
#    already checks without the flag. This is the actual regression net:
#    it proves none of the real, working programs in the existing suite
#    trip either check -- i.e. the current compiler leaves no stack trash
#    behind across all of them.
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

fail=0
count=0
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "--- detector sanity fixtures (tests/stack_check_cases/) ---"
for src in tests/stack_check_cases/*.asm; do
    count=$((count + 1))
    name=$(basename "$src" .asm)
    base="tests/stack_check_cases/$name"

    if ! nasm -f elf64 -o "$workdir/$name.o" "$src" 2>"$workdir/$name.nasm_err"; then
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
    if [[ -f "${base}.expected.stderr" ]] && \
       ! diff -u "${base}.expected.stderr" "$workdir/$name.stderr"; then
        echo "FAIL (stderr): $name"
        fail=1
    fi
done

echo "--- full codegen_cases suite, recompiled with POSTULATE_STACK_CHECK=1 ---"
for src in tests/codegen_cases/*.ptl; do
    name=$(basename "$src" .ptl)
    base="tests/codegen_cases/$name"

    # Fixtures that never reach a successful compile (codegen_fail, exit
    # 4) never emit any of the instrumented-only code paths -- the flag
    # cannot change their outcome, so skip them here (already covered by
    # run_codegen_tests.sh).
    if [[ -f "${base}.expected.codegen_exit" ]]; then
        continue
    fi

    count=$((count + 1))
    POSTULATE_STACK_CHECK=1 ./build/codegen < "$src" > "$workdir/$name.asm" 2>"$workdir/$name.codegen_err"
    codegen_code=$?
    if [[ "$codegen_code" != 0 ]]; then
        echo "FAIL (codegen exit $codegen_code != 0 under POSTULATE_STACK_CHECK=1): $name"
        cat "$workdir/$name.codegen_err"
        fail=1
        continue
    fi

    if ! nasm -f elf64 -o "$workdir/$name.o" "$workdir/$name.asm" 2>"$workdir/$name.nasm_err"; then
        echo "FAIL (nasm assemble, instrumented): $name"
        cat "$workdir/$name.nasm_err"
        fail=1
        continue
    fi
    if ! ld -static -no-pie -e _start -o "$workdir/$name.bin" "$workdir/$name.o" 2>"$workdir/$name.ld_err"; then
        echo "FAIL (ld link, instrumented): $name"
        cat "$workdir/$name.ld_err"
        fail=1
        continue
    fi

    "$workdir/$name.bin" > "$workdir/$name.stdout" 2>"$workdir/$name.stderr"
    actual_exit=$?
    expected_exit=$(cat "${base}.expected.exit")
    if [[ "$actual_exit" != "$expected_exit" ]]; then
        if [[ "$actual_exit" == 112 ]]; then
            echo "FAIL (stack canary corrupted under instrumentation): $name"
        elif [[ "$actual_exit" == 113 ]]; then
            echo "FAIL (stack pointer imbalance under instrumentation): $name"
        else
            echo "FAIL (exit $actual_exit != $expected_exit under POSTULATE_STACK_CHECK=1): $name"
        fi
        fail=1
    fi

    if [[ -f "${base}.expected.stdout" ]] && \
       ! diff -u "${base}.expected.stdout" "$workdir/$name.stdout"; then
        echo "FAIL (stdout, instrumented): $name"
        fail=1
    fi
done

echo "Ran $count fixture(s)."
exit $fail
