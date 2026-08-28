# Postulate
A statically-typed, C-like systems programming language designed for formal correctness proofs (Hoare logic), built as the foundation of a custom hobby operating system.

## Compilers

- **Hoare** — the Stage 0 compiler (hand-written x86_64 NASM, no libc), compiling **Postulate v0**. See [Hoare/README.md](Hoare/README.md) for building it, running its test suite, using the `./hoare` CLI, and the release Docker image.
- **Edsger** — the Stage 1 compiler, self-hosted (written in Postulate itself), compiling **Postulate v1.0** — v0 plus namespaces/`use`, `char`, `as`, pointer arithmetic, `*void`, `uintptr`, `sizeof`/`lengthof`, and raw-syscall `extern function`s. See [Edsger_v0/README.md](Edsger_v0/README.md) for building it, running its test suite, using the `./edsger` CLI, and the release Docker image.

## Language references

- [docs/postulate_v0_language_reference.md](docs/postulate_v0_language_reference.md) — Postulate v0, what Hoare compiles.
- [docs/postulate_v1_0_language_reference.md](docs/postulate_v1_0_language_reference.md) — Postulate v1.0, what Edsger compiles today — the practical reference for anyone just writing code.
- [docs/postulate_v1_language_reference.md](docs/postulate_v1_language_reference.md) — the full v1 language *design* (target, not all implemented yet — see the v1.0 reference's own §8 for the gap).
