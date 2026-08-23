#!/usr/bin/env bash
# Runs Stage1/tests/include_cases/* against a built stage1_lexer binary,
# and the existing Hoare/tests/cases/* single-file suite as the
# regression check (fixture 6 in docs/postulate_stage1_v1_0_1_include_
# design.md's "Testing plan" -- a program with zero #include lines must
# behave identically to before this pass existed).
#
# Usage: STAGE1_LEXER=/path/to/stage1_lexer scripts/run_include_tests.sh
# (run from the Stage1/tests directory, or pass its absolute path below)

set -u
BIN="${STAGE1_LEXER:-/tmp/stage1_lexer}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
ran=0

check_one() {
  local dir="$1" entry="$2"
  local out err ec
  out=$(mktemp)
  err=$(mktemp)
  ( cd "$dir" && "$BIN" < "$entry" > "$out" 2> "$err" )
  ec=$?
  ran=$((ran + 1))

  if [ -f "$dir/expected.exit" ]; then
    exp_exit=$(cat "$dir/expected.exit")
    if [ "$ec" != "$exp_exit" ]; then
      echo "FAIL $dir/$entry: exit=$ec want=$exp_exit"
      fail=1
    fi
  fi
  if [ -f "$dir/expected.stdout" ]; then
    if ! diff -q "$dir/expected.stdout" "$out" > /dev/null; then
      echo "FAIL $dir/$entry: stdout mismatch"
      diff "$dir/expected.stdout" "$out"
      fail=1
    fi
  fi
  if [ -f "$dir/expected.stderr" ]; then
    if ! diff -q "$dir/expected.stderr" "$err" > /dev/null; then
      echo "FAIL $dir/$entry: stderr mismatch"
      diff "$dir/expected.stderr" "$err"
      fail=1
    fi
  fi
  rm -f "$out" "$err"
}

for dir in "$HERE"/include_cases/*/; do
  dir="${dir%/}"
  entry_dir="$dir"
  # 05_relative_paths keeps its entry file under src/, matching the
  # cwd-relative resolution the entry file (index 0) is stuck with
  # until v1.0.11 gives Stage 1 real argv -- see the include design
  # doc's "Path resolution".
  if [ -f "$dir/src/main.ptl" ]; then
    entry_dir="$dir/src"
  fi
  shopt -s nullglob
  mains=("$entry_dir"/main*.ptl)
  shopt -u nullglob
  for m in "${mains[@]}"; do
    check_one "$entry_dir" "$(basename "$m")"
  done
done

echo "Ran $ran include fixture(s)."

echo "--- regression: Hoare/tests/cases/* (zero-#include programs) ---"
CASES_DIR="$HERE/../../Hoare/tests/cases"
if [ -d "$CASES_DIR" ]; then
  for f in "$CASES_DIR"/*.ptl; do
    base="${f%.ptl}"
    out=$(mktemp)
    err=$(mktemp)
    "$BIN" < "$f" > "$out" 2> "$err"
    ec=$?
    ran=$((ran + 1))
    if ! diff -q "$base.expected.stdout" "$out" > /dev/null; then
      echo "FAIL regression $base: stdout mismatch"
      fail=1
    fi
    if ! diff -q "$base.expected.stderr" "$err" > /dev/null; then
      echo "FAIL regression $base: stderr mismatch"
      diff "$base.expected.stderr" "$err"
      fail=1
    fi
    exp_exit=$(cat "$base.expected.exit")
    if [ "$ec" != "$exp_exit" ]; then
      echo "FAIL regression $base: exit=$ec want=$exp_exit"
      fail=1
    fi
    rm -f "$out" "$err"
  done
  echo "Ran $ran total fixture(s) (including regression)."
fi

if [ "$fail" != "0" ]; then
  echo "FAILURES DETECTED"
  exit 1
fi
echo "ALL INCLUDE FIXTURES PASSED"
