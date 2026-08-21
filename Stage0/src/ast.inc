; Postulate Stage 0 -- AST node kind constants and 40-byte node layout.
; See docs/postulate_stage0_parser_spec.md section 4.

AST_TY_BASE       equ 1
AST_TY_POINTER    equ 2
AST_TY_ARRAY      equ 3

AST_EX_INT        equ 10
AST_EX_BOOL       equ 11
AST_EX_NULL       equ 12
AST_EX_IDENT      equ 13
AST_EX_UNARY      equ 14
AST_EX_BINARY     equ 15
AST_EX_INDEX      equ 16
AST_EX_FIELD      equ 17
AST_EX_CALL       equ 18
AST_EX_STRUCT_LIT equ 19
AST_EX_ARRAY_LIT  equ 20
AST_FIELD_INIT    equ 21

; 4 generic qword fields (a/b/c/d) -- meaning depends on `kind`, see the
; parser spec's node-layout table. kind + 4 qwords = 40 bytes.
AST_NODE_SIZE equ 40
AST_KIND_OFF  equ 0
AST_A_OFF     equ 8
AST_B_OFF     equ 16
AST_C_OFF     equ 24
AST_D_OFF     equ 32
