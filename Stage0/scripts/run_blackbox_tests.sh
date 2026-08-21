#!/usr/bin/env bash
# Runs every fixture under tests/blackbox_cases/*.ptl against build/parser and
# diffs stdout/stderr/exit-code against the checked-in .expected.* files.
#
# Distinct in kind from run_parser_tests.sh: these fixtures are not scoped to
# a single grammar rule via a directive picked to exercise one routine --
# every fixture here is a complete, realistic PROGRAM (classic "programozasi
# tetel" implementations, combinations of them, and one large multi-
# declaration program), treating build/parser as a black box. See
# docs/postulate_stage0_parser_spec.md section 16.
set -uo pipefail
cd "$(dirname "$0")/.."
shopt -s nullglob

fail=0
count=0

for src in tests/blackbox_cases/*.ptl; do
    count=$((count + 1))
    name=$(basename "$src" .ptl)
    base="tests/blackbox_cases/$name"

    ./build/parser < "$src" > /tmp/actual_out 2>/tmp/actual_err
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
