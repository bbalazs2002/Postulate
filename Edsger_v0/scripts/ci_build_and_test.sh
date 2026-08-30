#!/usr/bin/env bash
# Builds and tests Edsger's dev + release Docker images. Shared by
# .github/workflows/release-edsger.yml (tag push) and test-edsger.yml
# (manual workflow_dispatch) so the two can never drift apart on the
# actual build commands -- this repo has hit that exact drift bug
# (the same command copied into several files, only some of them kept
# up to date) more than once already.
#
# Run from the repository root.
set -euo pipefail

echo "Runner: $(uname -m)"
docker version --format 'Docker {{.Server.Version}} (server arch {{.Server.Arch}})'

# --provenance=false --sbom=false: harmless CI hygiene (skips writing
# extra attestation manifests this script doesn't use) -- NOT a fix for
# anything below; kept for the `docker inspect` diagnostics to stay
# simple. The real "cannot execute binary file" / exit 126 bug (see the
# docker run below) turned out to be unrelated: Edsger_v0/Dockerfile
# sets `ENTRYPOINT ["/bin/bash"]`, so `docker run image bash -c "..."`
# actually execs `/bin/bash bash -c "..."` -- bash's own argv[1] is the
# literal string "bash", which it treats as a script *file* to run
# (not a flag), finds the real /usr/bin/bash binary via PATH, and
# refuses to interpret a binary file as a script. Fixed below with
# `--entrypoint bash` instead of passing "bash" as part of the command.
BUILD_FLAGS=(--provenance=false --sbom=false)

docker build "${BUILD_FLAGS[@]}" -f Edsger_v0/Dockerfile -t postulate-edsger Edsger_v0
docker inspect postulate-edsger --format 'postulate-edsger: Os={{.Os}} Architecture={{.Architecture}}'

# Runs Edsger_v0/scripts/build.sh's own two-stage bootstrap (codegen_
# selfhost, then the real src/modular/ source) inside its builder
# stage; see Edsger_v0/Dockerfile.release's own header comment.
docker build "${BUILD_FLAGS[@]}" -f Edsger_v0/Dockerfile.release -t postulate-edsger-release Edsger_v0
docker inspect postulate-edsger-release --format 'postulate-edsger-release: Os={{.Os}} Architecture={{.Architecture}}'

# codegen_cases fixtures, run directly against the real, released
# build/codegen -- baked into postulate-edsger-release at
# /opt/edsger/build/codegen (not the historical single-file
# src/codegen.ptl that Edsger_v0/tests/run_all_tests.sh's own
# run_codegen_tests.sh checks). Deliberately NOT run against
# postulate-edsger (the dev image): that image never bakes in Edsger's
# own source or a built binary (see its own header comment) -- only
# postulate-edsger-release's own build stage actually produces
# build/codegen, so testing against it is what makes this check mean
# anything on a fresh checkout, not just on a machine that happens to
# have a stray local build/codegen already lying around.
docker run --rm -v "$PWD/Edsger_v0/tests:/tests" --entrypoint bash postulate-edsger-release -c "
  set -e
  for f in /tests/codegen_cases/*.ptl; do
    base=\"\${f%.ptl}\"
    out=\$(mktemp); err=\$(mktemp)
    /opt/edsger/build/codegen < \"\$f\" > \"\$out\" 2> \"\$err\"
    diff -q \"\$base.expected.stdout\" \"\$out\"
    diff -q \"\$base.expected.stderr\" \"\$err\"
    rm -f \"\$out\" \"\$err\"
  done
  echo 'codegen_cases: all passed against build/codegen'
"
