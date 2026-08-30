#!/usr/bin/env bash
# Runs Edsger/src/sema.ptl (v1.0.6, Module 3 -- SECOND SLICE: real
# tokenize+parse, @autoload resolution, symbol-table declare pass,
# struct layout/value-cycle detection, and now real multi-file `use`
# discovery via sys_openat; see that file's own header) against every
# fixture in sema_cases/, comparing stdout/stderr/exit code against the
# recorded .expected.* files -- same convention run_lexer_tests.sh/
# run_parser_tests.sh already use.
#
# Two fixture shapes:
#   - a plain "<name>.ptl" file: single-file case, fed on stdin, same
#     as before.
#   - a "<name>/" directory containing "entry.ptl" (+ whatever other
#     .ptl files it `use`s, laid out on disk exactly as the default 1:1
#     mapping or an @autoload rule would resolve them): a multi-file
#     case. The binary is run with its OWN working directory set to
#     that fixture's directory (sys_openat resolves relative to
#     AT_FDCWD, i.e. the process's cwd), with entry.ptl fed on stdin.
#
# Run from inside Edsger/Dockerfile's own image (see docker-compose.yml's
# "edsger-dev" service -- `hoare` is already built and on PATH there),
# or on any host with `hoare` on PATH or checked out at Hoare/hoare next
# to this repo, with nasm/ld already installed:
#
#   Edsger/tests/run_sema_tests.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CASES_DIR="$SCRIPT_DIR/sema_cases"
BIN="$(mktemp)"

if command -v hoare > /dev/null 2>&1; then
    HOARE_CMD="hoare"
elif [ -x "$REPO_ROOT/Hoare/hoare" ]; then
    HOARE_CMD="$REPO_ROOT/Hoare/hoare"
else
    echo "run_sema_tests.sh: no 'hoare' on PATH and $REPO_ROOT/Hoare/hoare not found -- see Edsger/Dockerfile" >&2
    exit 64
fi

"$HOARE_CMD" "$REPO_ROOT/Edsger/src/sema.ptl" -o "$BIN"

pass=0
fail=0

# check_result <name> <expected_base> <actual_out> <actual_err> <actual_code>
check_result() {
    local name="$1" expected_base="$2" out="$3" err="$4" code="$5"
    local ok=1
    if ! diff -q "$expected_base.expected.stdout" "$out" > /dev/null; then
        echo "FAIL $name: stdout mismatch"
        diff "$expected_base.expected.stdout" "$out"
        ok=0
    fi
    if ! diff -q "$expected_base.expected.stderr" "$err" > /dev/null; then
        echo "FAIL $name: stderr mismatch"
        diff "$expected_base.expected.stderr" "$err"
        ok=0
    fi
    local expected_exit
    expected_exit="$(cat "$expected_base.expected.exit")"
    if [ "$code" != "$expected_exit" ]; then
        echo "FAIL $name: exit $code, expected $expected_exit"
        ok=0
    fi
    if [ "$ok" = "1" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
}

for f in "$CASES_DIR"/*.ptl; do
    [ -e "$f" ] || continue
    base="${f%.ptl}"
    name="$(basename "$base")"
    out="$(mktemp)"
    err="$(mktemp)"
    "$BIN" < "$f" > "$out" 2> "$err"
    code=$?
    check_result "$name" "$base" "$out" "$err" "$code"
    rm -f "$out" "$err"
done

for d in "$CASES_DIR"/*/; do
    [ -e "$d/entry.ptl" ] || continue
    name="$(basename "$d")"
    out="$(mktemp)"
    err="$(mktemp)"
    ( cd "$d" && "$BIN" < entry.ptl > "$out" 2> "$err" )
    code=$?
    check_result "$name" "${d%/}/entry" "$out" "$err" "$code"
    rm -f "$out" "$err"
done

rm -f "$BIN"
echo "sema tests: $pass passed, $fail failed"
[ "$fail" = "0" ]
