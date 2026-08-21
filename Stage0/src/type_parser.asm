; Postulate Stage 0 -- type parser.
; See docs/postulate_stage0_parser_spec.md section 6.

%include "tokens.inc"
%include "ast.inc"

extern tok_cur
extern parser_advance
extern parser_peek
extern parser_expect
extern report_parse_error
extern ast_alloc_node

global parse_type
global parse_base_type
global token_starts_base_type

section .data
msg_expected_type:     db "expected type"
msg_expected_type_len  equ $ - msg_expected_type
msg_expected_lbracket:    db "expected '['"
msg_expected_lbracket_len equ $ - msg_expected_lbracket
msg_expected_size:          db "expected integer literal for array size"
msg_expected_size_len       equ $ - msg_expected_size
msg_expected_rbracket:         db "expected ']'"
msg_expected_rbracket_len      equ $ - msg_expected_rbracket
msg_expected_rparen:               db "expected ')'"
msg_expected_rparen_len            equ $ - msg_expected_rparen

section .text

; ===========================================================================
; token_starts_base_type: in rdi = TOK_* kind; out rax = 1/0.
; NOTE: relies on tokens.inc laying out all 11 builtin-type keywords
; contiguously at TOK_KW_INT8(22)..TOK_KW_BOOL(32) -- a single range check.
; If that ordering ever changes in tokens.inc, this must be revisited.
; ===========================================================================
token_starts_base_type:
    cmp     rdi, TOK_IDENT
    je      .yes
    cmp     rdi, TOK_KW_INT8
    jl      .no
    cmp     rdi, TOK_KW_BOOL
    jg      .no
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ===========================================================================
; parse_base_type: consumes exactly one token (tok_cur must already satisfy
; token_starts_base_type -- callers check this before calling). out: rax =
; AST_TY_BASE node.
; ===========================================================================
parse_base_type:
    mov     r12, [tok_cur + TOK_KIND_OFF]
    mov     r13, [tok_cur + TOK_OFFSET_OFF]
    mov     r14, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, AST_TY_BASE
    call    ast_alloc_node
    cmp     r12, TOK_IDENT
    jne     .builtin
    mov     qword [rax + AST_A_OFF], 0
    jmp     .common
.builtin:
    mov     [rax + AST_A_OFF], r12
.common:
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    ret

; ===========================================================================
; parse_type: dispatches purely on tok_cur.kind, zero backtracking (spec
; section 6). out: rax = node ptr.
; ===========================================================================
parse_type:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_STAR
    je      .star
    cmp     rax, TOK_LPAREN
    je      .paren
    mov     rdi, rax
    call    token_starts_base_type
    cmp     rax, 0
    jne     .based
    mov     rsi, msg_expected_type
    mov     rdx, msg_expected_type_len
    jmp     report_parse_error

; --- "*" base_type "[" INT "]"  (default: array of N pointers)
; --- or "*" type                (general: pointer to <type>)
.star:
    call    parser_advance                  ; consume '*'
    mov     rax, [tok_cur + TOK_KIND_OFF]
    mov     rdi, rax
    call    token_starts_base_type
    cmp     rax, 0
    je      .star_general
    call    parser_peek                     ; rax = &tok_peek, does not consume
    mov     rax, [rax + TOK_KIND_OFF]
    cmp     rax, TOK_LBRACKET
    jne     .star_general
    ; default form
    call    parse_base_type
    mov     r12, rax
    mov     rdi, AST_TY_POINTER
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     r12, rax                        ; r12 = pointer node (array's elem)
    mov     rdi, TOK_LBRACKET
    mov     rsi, msg_expected_lbracket
    mov     rdx, msg_expected_lbracket_len
    call    parser_expect
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_INT
    je      .star_have_size
    mov     rsi, msg_expected_size
    mov     rdx, msg_expected_size_len
    call    report_parse_error
.star_have_size:
    mov     r13, [tok_cur + TOK_VALUE_OFF]
    call    parser_advance
    mov     rdi, TOK_RBRACKET
    mov     rsi, msg_expected_rbracket
    mov     rdx, msg_expected_rbracket_len
    call    parser_expect
    mov     rdi, AST_TY_ARRAY
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    ret
.star_general:
    call    parse_type                      ; recursive: general "pointer to <type>"
    mov     r12, rax
    mov     rdi, AST_TY_POINTER
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    ret

; --- "(" type ")"  -- transparent grouping, no wrapper node
.paren:
    call    parser_advance                  ; consume '('
    call    parse_type                      ; recursive
    mov     r12, rax
    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect
    mov     rax, r12
    ret

; --- base_type "[" INT "]"  or  bare base_type
.based:
    call    parse_base_type
    mov     r12, rax
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_LBRACKET
    jne     .based_done
    call    parser_advance
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_INT
    je      .based_have_size
    mov     rsi, msg_expected_size
    mov     rdx, msg_expected_size_len
    call    report_parse_error
.based_have_size:
    mov     r13, [tok_cur + TOK_VALUE_OFF]
    call    parser_advance
    mov     rdi, TOK_RBRACKET
    mov     rsi, msg_expected_rbracket
    mov     rdx, msg_expected_rbracket_len
    call    parser_expect
    mov     rdi, AST_TY_ARRAY
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    ret
.based_done:
    mov     rax, r12
    ret
