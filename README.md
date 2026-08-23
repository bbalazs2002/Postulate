# Postulate
A statically-typed, C-like systems programming language designed for formal correctness proofs (Hoare logic), built as the foundation of a custom hobby operating system.

## Compiler

Postulate is bootstrapped through **Hoare**, the Stage 0 compiler (hand-written x86_64 NASM, no libc). See [Hoare/README.md](Hoare/README.md) for building it, running its test suite, using the `./hoare` CLI, and the release Docker image.

## Language reference

[docs/postulate_v0_language_reference.md](docs/postulate_v0_language_reference.md) is the full technical reference for the language itself.
