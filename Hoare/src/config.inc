; Postulate Stage 0 -- shared size constants.
; See docs/postulate_stage0_lexer_spec.md section 8.1.

SRC_BUF_SIZE equ 1024*1024   ; 1 MiB fixed source buffer
OUT_BUF_SIZE equ 65536       ; 64 KiB fixed output-formatting buffer

; See docs/postulate_stage0_parser_spec.md section 4.3. Bumped from the
; original 1 MiB (~26,000 nodes) to fit Stage 1's own source files
; (Stage1/src/*.ptl) once they grew past that -- v0's own verbosity (no
; operator overloading, no sugar, every identifier/literal/operator its
; own node) means even a few thousand lines of *source* need well over
; 26,000 AST nodes. .bss cost is free (zero on-disk size, only a
; runtime reservation), so there is no real downside to being generous.
AST_ARENA_SIZE equ 1024*1024*16 ; 16 MiB fixed AST node arena
MAX_LIST_ARITY equ 256       ; per-list cap (call args / struct fields / array elems)
