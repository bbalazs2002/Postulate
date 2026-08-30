#!/usr/bin/env bash
# Runs every Edsger/tests/run_*_tests.sh script in turn and reports a
# combined pass/fail. Add a new module's own run_<name>_tests.sh next
# to this file (matching run_lexer_tests.sh's own shape) and it picks
# it up automatically -- nothing here needs editing per module.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

overall=0
for runner in "$SCRIPT_DIR"/run_*_tests.sh; do
    [ "$runner" = "$SCRIPT_DIR/run_all_tests.sh" ] && continue
    name="$(basename "$runner")"
    echo "== $name =="
    if ! "$runner"; then
        overall=1
    fi
    echo
done

exit "$overall"
