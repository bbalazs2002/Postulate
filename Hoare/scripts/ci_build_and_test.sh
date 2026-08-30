#!/usr/bin/env bash
# Builds and tests Hoare's dev + release Docker images. Shared by
# .github/workflows/release-hoare.yml (tag push) and test-hoare.yml
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
# "cannot execute binary file" / exit 126 running e.g. bash inside it
# (hit for real in scripts/bundle_release.sh's own
# `docker run --entrypoint bash ...`). Diagnostic `docker inspect`
# calls below print each image's actual Os/Architecture so a
# recurrence of that failure is easier to tell apart from a genuine
# cross-arch build.
BUILD_FLAGS=(--provenance=false --sbom=false)

# Builds all four binaries and runs every fixture suite as part of the
# image build itself (Hoare/Dockerfile's own RUN steps) -- a failing
# test fails this line, gating everything after it.
docker build "${BUILD_FLAGS[@]}" -t postulate-hoare Hoare
docker inspect postulate-hoare --format 'postulate-hoare: Os={{.Os}} Architecture={{.Architecture}}'

# Re-packages the already-tested binaries above; see
# Hoare/Dockerfile.release's own header comment.
docker build "${BUILD_FLAGS[@]}" -f Hoare/Dockerfile.release -t postulate-hoare-release Hoare
docker inspect postulate-hoare-release --format 'postulate-hoare-release: Os={{.Os}} Architecture={{.Architecture}}'
