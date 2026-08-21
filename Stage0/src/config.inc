; Postulate Stage 0 -- shared size constants.
; See docs/postulate_stage0_lexer_spec.md section 8.1.

SRC_BUF_SIZE equ 1024*1024   ; 1 MiB fixed source buffer
OUT_BUF_SIZE equ 65536       ; 64 KiB fixed output-formatting buffer

; See docs/postulate_stage0_parser_spec.md section 4.3.
AST_ARENA_SIZE equ 1024*1024 ; 1 MiB fixed AST node arena
MAX_LIST_ARITY equ 256       ; per-list cap (call args / struct fields / array elems)
