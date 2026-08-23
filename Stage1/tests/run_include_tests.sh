#!/usr/bin/env bash
# Runs Stage1/tests/include_cases/* against one of the three tripled
# resolve_includes copies (lexer.ptl/parser.ptl/codegen.ptl -- see the
# include design doc's "Where the pass lives"). For BINARY_KIND=lexer
# only, also runs the existing Hoare/tests/cases/* single-file suite as
# the regression check (fixture 6 in docs/postulate_stage1_v1_0_1_
# include_design.md's "Testing plan").
#
# Usage:
#   STAGE1_LEXER=/path/to/stage1_lexer scripts/run_include_tests.sh
#   BINARY_KIND=parser STAGE1_LEXER=/path/to/stage1_parser scripts/run_include_tests.sh
#   BINARY_KIND=codegen STAGE1_LEXER=/path/to/stage1_codegen scripts/run_include_tests.sh
#
# expected.exit is checked for every binary kind (exit codes are the one
# thing all three phases agree on: 0/1/2). expected.stdout/expected.stderr
# are only compared for BINARY_KIND=lexer -- parser.ptl and codegen.ptl
# each have their own diagnostic wording (AST dump vs NASM output, "lex
# error (see stderr...)" vs the lexer's own message text), so a shared
# expected.stderr authored against the lexer's wording isn't meaningful
# for them; their diagnostics are still exercised (and their exit codes
# checked), just not compared byte-for-byte here.

set -u
BIN="${STAGE1_LEXER:-/tmp/stage1_lexer}"
KIND="${BINARY_KIND:-lexer}"
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
      cat "$err"
      fail=1
    fi
  fi
  if [ "$KIND" = "lexer" ]; then
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

echo "Ran $ran include fixture(s) (BINARY_KIND=$KIND)."

if [ "$KIND" != "lexer" ]; then
  if [ "$fail" != "0" ]; then
    echo "FAILURES DETECTED"
    exit 1
  fi
  echo "ALL INCLUDE FIXTURES PASSED (exit codes only -- see header for why stdout/stderr aren't compared for BINARY_KIND=$KIND)"
  exit 0
fi

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
