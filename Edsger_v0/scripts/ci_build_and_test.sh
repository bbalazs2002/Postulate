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

# --provenance=false --sbom=false: without these, GitHub-hosted
# runners' Docker can emit a multi-manifest (attestation) image even
# for a plain `docker build`, and a later `docker run` against it may
# pick the non-runnable attestation manifest instead of the real one --
# "cannot execute binary file" / exit 126 running e.g. bash inside it.
# Diagnostic `docker inspect` calls below print each image's actual
# Os/Architecture so a recurrence of that failure is easier to tell
# apart from a genuine cross-arch build.
BUILD_FLAGS=(--provenance=false --sbom=false)

docker build "${BUILD_FLAGS[@]}" -f Edsger_v0/Dockerfile -t postulate-edsger .
docker inspect postulate-edsger --format 'postulate-edsger: Os={{.Os}} Architecture={{.Architecture}}'

# Runs Edsger_v0/scripts/build.sh's own two-stage bootstrap (codegen_
# selfhost, then the real src/modular/ source) inside its builder
# stage; see Edsger_v0/Dockerfile.release's own header comment.
docker build "${BUILD_FLAGS[@]}" -f Edsger_v0/Dockerfile.release -t postulate-edsger-release .
docker inspect postulate-edsger-release --format 'postulate-edsger-release: Os={{.Os}} Architecture={{.Architecture}}'

# codegen_cases fixtures, run directly against the real, released
# build/codegen (not the historical single-file src/codegen.ptl that
# Edsger_v0/tests/run_all_tests.sh's own run_codegen_tests.sh checks).
docker run --rm -v "$PWD/Edsger_v0:/workspace/Edsger" postulate-edsger bash -c "
  set -e
  for f in tests/codegen_cases/*.ptl; do
    base=\"\${f%.ptl}\"
    out=\$(mktemp); err=\$(mktemp)
    ./build/codegen < \"\$f\" > \"\$out\" 2> \"\$err\"
    diff -q \"\$base.expected.stdout\" \"\$out\"
    diff -q \"\$base.expected.stderr\" \"\$err\"
    rm -f \"\$out\" \"\$err\"
  done
  echo 'codegen_cases: all passed against build/codegen'
"
