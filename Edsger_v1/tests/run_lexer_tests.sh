#!/usr/bin/env bash
# Runs Edsger/src/lexer.ptl (v1.0.6, Module 1) against every fixture in
# lexer_cases/, comparing stdout/stderr/exit code against the recorded
# .expected.* files -- same convention Hoare/Stage1's own test scripts
# already use. Run from inside Edsger/Dockerfile's own image (see
# docker-compose.yml's "edsger-dev" service -- `hoare` is already built
# and on PATH there, Hoare/ itself is not mounted at all), or on any
# host with `hoare` on PATH or checked out at Hoare/hoare next to this
# repo, with nasm/ld already installed:
#
#   Edsger/tests/run_lexer_tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CASES_DIR="$SCRIPT_DIR/lexer_cases"
BIN="$(mktemp)"

if command -v hoare > /dev/null 2>&1; then
    HOARE_CMD="hoare"
elif [ -x "$REPO_ROOT/Hoare/hoare" ]; then
    HOARE_CMD="$REPO_ROOT/Hoare/hoare"
else
    echo "run_lexer_tests.sh: no 'hoare' on PATH and $REPO_ROOT/Hoare/hoare not found -- see Edsger/Dockerfile" >&2
    exit 64
fi

"$HOARE_CMD" "$REPO_ROOT/Edsger/src/lexer.ptl" -o "$BIN"

pass=0
fail=0

for f in "$CASES_DIR"/*.ptl; do
    base="${f%.ptl}"
    name="$(basename "$base")"
    out="$(mktemp)"
    err="$(mktemp)"
    "$BIN" < "$f" > "$out" 2> "$err"
    code=$?

    ok=1
    if ! diff -q "$base.expected.stdout" "$out" > /dev/null; then
        echo "FAIL $name: stdout mismatch"
        diff "$base.expected.stdout" "$out"
        ok=0
    fi
    if ! diff -q "$base.expected.stderr" "$err" > /dev/null; then
        echo "FAIL $name: stderr mismatch"
        diff "$base.expected.stderr" "$err"
        ok=0
    fi
    expected_exit="$(cat "$base.expected.exit")"
    if [ "$code" != "$expected_exit" ]; then
        echo "FAIL $name: exit $code, expected $expected_exit"
        ok=0
    fi

    if [ "$ok" = "1" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
    rm -f "$out" "$err"
done

rm -f "$BIN"
echo "lexer tests: $pass passed, $fail failed"
[ "$fail" = "0" ]
