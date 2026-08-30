# Edsger v1.1.n (in-progress rewrite)

A self-contained sibling of `Edsger_v0/`: same modular source layout
and test structure, but with a growing set of v1.1.n language
additions (see `docs/postulate_stage1_bootstrap_plan.md` for what's
landed so far — n-way `if`/`elseif`, `break`/`continue`, `ref`
parameters, struct field reordering, and more).

## Self-contained

This directory needs nothing outside itself to build or test —
neither Hoare's nor Edsger_v0's own source. The one thing it *would*
otherwise need from Edsger_v0 (the `codegen_selfhost` bootstrap binary
— see `scripts/build.sh`'s own header comment for what that is and why
it's needed) is vendored in as an already-built binary,
`vendor/codegen_selfhost/`, extracted once from a verified Edsger_v0
build. The v1.0 language reference it packages for its own release
image is vendored the same way, at `vendor/docs/`.

## Build and test

```powershell
docker build -f Edsger_v1/Dockerfile -t postulate-edsger-v1 Edsger_v1
docker build -f Edsger_v1/Dockerfile.release -t postulate-edsger-v1-release Edsger_v1
```

Then, same as Edsger_v0:

```bash
Edsger_v1/tests/run_all_tests.sh
```

or the full dev+release build/test gate:

```bash
Edsger_v1/scripts/ci_build_and_test.sh
```

## Relationship to Edsger_v0

Edsger_v1 is not a permanent fork — it's the working copy for the
v1.1.n language rewrite while it's still in progress. Whenever a
feature batch here (Sema round, Codegen round, ...) is complete and
verified, the same change eventually needs porting back to a real v1.1
release; until then, this directory is where that work actually lives
and gets tested, independently of Edsger_v0 (which stays frozen at its
own v1.0 behavior).
