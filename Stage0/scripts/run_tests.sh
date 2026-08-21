#!/usr/bin/env bash
# Runs every fixture under tests/cases/*.ptl against build/lexer and diffs
# stdout/stderr/exit-code against the checked-in .expected.* files.
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

fail=0
count=0

for src in tests/cases/*.ptl; do
    count=$((count + 1))
    name=$(basename "$src" .ptl)
    base="tests/cases/$name"

    ./build/lexer < "$src" > /tmp/actual_out 2>/tmp/actual_err
    actual_code=$?

    if ! diff -u "${base}.expected.stdout" /tmp/actual_out; then
        echo "FAIL (stdout): $name"
        fail=1
    fi

    if ! diff -u "${base}.expected.stderr" /tmp/actual_err; then
        echo "FAIL (stderr): $name"
        fail=1
    fi

    expected_code=$(cat "${base}.expected.exit")
    if [[ "$actual_code" != "$expected_code" ]]; then
        echo "FAIL (exit $actual_code != $expected_code): $name"
        fail=1
    fi
done

echo "Ran $count fixture(s)."
exit $fail
