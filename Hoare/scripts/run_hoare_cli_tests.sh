#!/usr/bin/env bash
# Smoke-tests the unified ./hoare CLI (see ../hoare) end to end: does
# `./hoare file.ptl` actually produce a runnable binary with the right
# exit code, does `--stack-trace` wire through to POSTULATE_STACK_CHECK
# correctly via this entry point specifically (not just via a direct
# build/codegen invocation, already covered by run_stack_check_tests.sh),
# does a codegen-rejected input propagate its exit code without hoare
# attempting to assemble/link garbage, and do basic usage errors exit 64.
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

fail=0
count=0
hoare_root="$(pwd)"
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

check_exit() {
    local desc="$1" actual="$2" expected="$3"
    count=$((count + 1))
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL ($desc: exit $actual != $expected)"
        fail=1
    fi
}

# --- a normal, successfully-compiling fixture, default output naming ---
src="tests/codegen_cases/23_composite_param.ptl"
expected=$(cat "tests/codegen_cases/23_composite_param.expected.exit")
( cd "$workdir" && "$hoare_root/hoare" "$hoare_root/$src" )
compile_code=$?
check_exit "hoare compile: $src" "$compile_code" 0
if [[ "$compile_code" -eq 0 ]]; then
    "$workdir/23_composite_param"
    check_exit "hoare-built binary: $src" "$?" "$expected"
fi

# --- same fixture, --stack-trace, explicit -o ---
"./hoare" "$src" --stack-trace -o "$workdir/checked_out"
check_exit "hoare compile --stack-trace: $src" "$?" 0
"$workdir/checked_out"
check_exit "hoare-built --stack-trace binary: $src" "$?" "$expected"

# --- a fixture build/codegen itself rejects: hoare must propagate the
# same exit code and never reach nasm/ld ---
src="tests/codegen_cases/29_composite_call_as_literal_field_deferred.ptl"
expected_codegen=$(cat "tests/codegen_cases/29_composite_call_as_literal_field_deferred.expected.codegen_exit")
"./hoare" "$src" -o "$workdir/should_not_exist" 2>"$workdir/rejected.err"
check_exit "hoare propagates codegen rejection: $src" "$?" "$expected_codegen"
count=$((count + 1))
if [[ -f "$workdir/should_not_exist" ]]; then
    echo "FAIL (hoare produced a binary for a codegen-rejected input): $src"
    fail=1
fi
count=$((count + 1))
if [[ ! -s "$workdir/rejected.err" ]]; then
    echo "FAIL (hoare printed no diagnostic for a codegen-rejected input): $src"
    fail=1
fi

# --- usage errors ---
"./hoare" >/dev/null 2>&1
check_exit "hoare with no arguments" "$?" 64
"./hoare" "tests/codegen_cases/does_not_exist.ptl" >/dev/null 2>&1
check_exit "hoare with a nonexistent file" "$?" 64

echo "Ran $count check(s)."
exit $fail
