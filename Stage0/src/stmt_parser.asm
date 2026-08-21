; Postulate Stage 0 -- statement / declaration / block parser.
; See docs/postulate_stage0_parser_spec.md section 9.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"

extern tok_cur
extern parser_advance
extern parser_expect
extern report_parse_error
extern ast_alloc_node
extern ast_alloc_bytes
extern parse_expr
extern parse_type

global parse_stmt
global parse_assign_or_expr_stmt
global parse_if_stmt
global parse_while_stmt
global parse_return_stmt
global parse_block
global parse_decl
global parse_func_block

section .data
msg_expected_assign: db "expected ':='"
msg_expected_assign_len equ $ - msg_expected_assign
msg_expected_semi:      db "expected ';'"
msg_expected_semi_len   equ $ - msg_expected_semi
msg_too_many_pairs:         db "too many assignment pairs"
msg_too_many_pairs_len      equ $ - msg_too_many_pairs
msg_expected_lparen:           db "expected '('"
msg_expected_lparen_len        equ $ - msg_expected_lparen
msg_expected_rparen:               db "expected ')'"
msg_expected_rparen_len            equ $ - msg_expected_rparen
msg_too_many_stmts:                    db "too many statements in block"
msg_too_many_stmts_len                 equ $ - msg_too_many_stmts
msg_expected_decl_name:                    db "expected declaration name"
msg_expected_decl_name_len                 equ $ - msg_expected_decl_name
msg_expected_colon:                            db "expected ':'"
msg_expected_colon_len                         equ $ - msg_expected_colon
msg_too_many_decls:                                db "too many declarations in block"
msg_too_many_decls_len                             equ $ - msg_too_many_decls

section .text

; ===========================================================================
; parse_stmt: stmt ::= assign_stmt | if_stmt | while_stmt | return_stmt
;                     | expr_stmt
; Pure dispatcher, tail calls only -- no registers to save.
; ===========================================================================
parse_stmt:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_IF
    je      parse_if_stmt
    cmp     rax, TOK_KW_WHILE
    je      parse_while_stmt
    cmp     rax, TOK_KW_RETURN
    je      parse_return_stmt
    jmp     parse_assign_or_expr_stmt

; ===========================================================================
; parse_assign_or_expr_stmt: the assign_stmt/expr_stmt disambiguation (spec
; section 9.1/9.3). Always parses a full expr first -- TOK_ASSIGN never
; appears in expr's own grammar, so parse_expr() is guaranteed to stop
; exactly at a ':=' when one follows. No backtracking, no dedicated lvalue
; parser; lvalue-shaped assignment targets reuse the same AST_EX_* node
; kinds expr already produces (AST_EX_IDENT/AST_EX_UNARY/AST_EX_INDEX/
; AST_EX_FIELD).
; ===========================================================================
parse_assign_or_expr_stmt:
    push    r12                  ; current lvalue-or-expr
    call    parse_expr
    mov     r12, rax

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_ASSIGN
    je      .is_assign

    ; --- expr_stmt ::= expr ";" ---
    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect
    mov     rdi, AST_STMT_EXPR
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    pop     r12
    ret

.is_assign:
    push    r13                  ; pair count
    push    r14                  ; rhs (per-iteration scratch)
    push    r15                  ; arena dest (set once, at commit)
    sub     rsp, MAX_LIST_ARITY*8
    xor     r13, r13
.pair_loop:
    ; consumes ':=' -- uniformly, including the first iteration, so every
    ; loop body is identical
    mov     rdi, TOK_ASSIGN
    mov     rsi, msg_expected_assign
    mov     rdx, msg_expected_assign_len
    call    parser_expect
    call    parse_expr                    ; rhs
    mov     r14, rax
    mov     rdi, AST_ASSIGN_PAIR
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12        ; lvalue
    mov     [rax + AST_B_OFF], r14        ; rhs
    mov     [rsp + r13*8], rax
    inc     r13
    cmp     r13, MAX_LIST_ARITY
    jae     .too_many
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_COMMA
    jne     .commit
    call    parser_advance                ; ','
    call    parse_expr                    ; next lvalue
    mov     r12, rax
    jmp     .pair_loop
.commit:
    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect
    mov     rdi, r13
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r15, rax
    xor     rcx, rcx
.copy_loop:
    cmp     rcx, r13
    jae     .copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r15 + rcx*8], rax
    inc     rcx
    jmp     .copy_loop
.copy_done:
    add     rsp, MAX_LIST_ARITY*8
    mov     rdi, AST_STMT_ASSIGN
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r15
    mov     [rax + AST_B_OFF], r13
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.too_many:
    mov     rsi, msg_too_many_pairs
    mov     rdx, msg_too_many_pairs_len
    call    report_parse_error

; ===========================================================================
; parse_if_stmt: if_stmt ::= "if" "(" expr ")" block ("else" block)?
; ===========================================================================
parse_if_stmt:
    push    r12                  ; cond
    push    r13                  ; then_block
    push    r14                  ; else_block (0 if absent)
    call    parser_advance                ; 'if'
    mov     rdi, TOK_LPAREN
    mov     rsi, msg_expected_lparen
    mov     rdx, msg_expected_lparen_len
    call    parser_expect
    call    parse_expr
    mov     r12, rax
    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect
    call    parse_block
    mov     r13, rax
    xor     r14, r14
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_ELSE
    jne     .no_else
    call    parser_advance                ; 'else'
    call    parse_block
    mov     r14, rax
.no_else:
    mov     rdi, AST_STMT_IF
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_while_stmt: while_stmt ::= "while" "(" expr ")" block
; ===========================================================================
parse_while_stmt:
    push    r12                  ; cond
    push    r13                  ; body
    call    parser_advance                ; 'while'
    mov     rdi, TOK_LPAREN
    mov     rsi, msg_expected_lparen
    mov     rdx, msg_expected_lparen_len
    call    parser_expect
    call    parse_expr
    mov     r12, rax
    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect
    call    parse_block
    mov     r13, rax
    mov     rdi, AST_STMT_WHILE
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_return_stmt: return_stmt ::= "return" expr? ";"
; tok_cur == TOK_SEMI immediately after 'return' unambiguously selects the
; empty-expr alternative -- no lookahead needed.
; ===========================================================================
parse_return_stmt:
    push    r12                  ; expr or 0
    call    parser_advance                ; 'return'
    xor     r12, r12
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_SEMI
    je      .no_expr
    call    parse_expr
    mov     r12, rax
.no_expr:
    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect
    mov     rdi, AST_STMT_RETURN
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    pop     r12
    ret

; ===========================================================================
; parse_block: block ::= "{" stmt* "}"  -- zero-or-more, no "empty is an
; error" check (unlike array/struct literals -- the grammar has "*" here,
; not "+").
; ===========================================================================
parse_block:
    push    r12                  ; count
    push    r13                  ; arena dest
    call    parser_advance                ; '{'
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    je      .commit
    call    parse_stmt
    mov     [rsp + r12*8], rax
    inc     r12
    cmp     r12, MAX_LIST_ARITY
    jae     .too_many
    jmp     .loop
.commit:
    call    parser_advance                ; '}'
    mov     rdi, r12
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r13, rax
    xor     rcx, rcx
.copy_loop:
    cmp     rcx, r12
    jae     .copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r13 + rcx*8], rax
    inc     rcx
    jmp     .copy_loop
.copy_done:
    add     rsp, MAX_LIST_ARITY*8
    mov     rdi, AST_BLOCK
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r13
    mov     [rax + AST_B_OFF], r12
    pop     r13
    pop     r12
    ret
.too_many:
    mov     rsi, msg_too_many_stmts
    mov     rdx, msg_too_many_stmts_len
    call    report_parse_error

; ===========================================================================
; parse_decl: decl ::= ("mut" | "const") identifier ":" type
;                       (":=" expr)? ";"
; ===========================================================================
parse_decl:
    push    rbx                  ; AST_DECL_MUT or AST_DECL_CONST
    push    r12                  ; name_offset
    push    r13                  ; name_len
    push    r14                  ; type ptr
    push    r15                  ; init ptr (0 if absent)

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_CONST
    je      .is_const
    mov     rbx, AST_DECL_MUT
    jmp     .kind_done
.is_const:
    mov     rbx, AST_DECL_CONST
.kind_done:
    call    parser_advance                ; consume 'mut'/'const'

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .have_name
    mov     rsi, msg_expected_decl_name
    mov     rdx, msg_expected_decl_name_len
    call    report_parse_error
.have_name:
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance

    mov     rdi, TOK_COLON
    mov     rsi, msg_expected_colon
    mov     rdx, msg_expected_colon_len
    call    parser_expect

    call    parse_type
    mov     r14, rax

    xor     r15, r15
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_ASSIGN
    jne     .no_init
    call    parser_advance                ; ':='
    call    parse_expr
    mov     r15, rax
.no_init:
    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect

    mov     rdi, rbx
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    mov     [rax + AST_D_OFF], r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; parse_func_block: func_block ::= "{" decl* stmt* "}"
; Two sequential (not nested) variable-arity lists reusing the same
; MAX_LIST_ARITY*8-byte scratch region one after another -- safe because the
; decl list fully commits to the arena (and its scratch is released) before
; the stmt list's scratch is allocated, so there's no overlap in time.
; Final register budget r12/r13/r14/r15 maps 1:1 onto AST_FUNC_BLOCK's own
; a/b/c/d fields.
; ===========================================================================
parse_func_block:
    push    r12                  ; decls ptr
    push    r13                  ; decl_count
    push    r14                  ; stmts ptr
    push    r15                  ; stmt_count
    call    parser_advance                ; '{'

    sub     rsp, MAX_LIST_ARITY*8
    xor     r13, r13
.decl_loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_MUT
    je      .decl_elem
    cmp     rax, TOK_KW_CONST
    je      .decl_elem
    jmp     .decl_commit
.decl_elem:
    call    parse_decl
    mov     [rsp + r13*8], rax
    inc     r13
    cmp     r13, MAX_LIST_ARITY
    jae     .too_many_decls
    jmp     .decl_loop
.decl_commit:
    mov     rdi, r13
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r12, rax
    xor     rcx, rcx
.decl_copy_loop:
    cmp     rcx, r13
    jae     .decl_copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r12 + rcx*8], rax
    inc     rcx
    jmp     .decl_copy_loop
.decl_copy_done:
    add     rsp, MAX_LIST_ARITY*8

    sub     rsp, MAX_LIST_ARITY*8
    xor     r15, r15
.stmt_loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    je      .stmt_commit
    call    parse_stmt
    mov     [rsp + r15*8], rax
    inc     r15
    cmp     r15, MAX_LIST_ARITY
    jae     .too_many_fb_stmts
    jmp     .stmt_loop
.stmt_commit:
    call    parser_advance                ; '}'
    mov     rdi, r15
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r14, rax
    xor     rcx, rcx
.stmt_copy_loop:
    cmp     rcx, r15
    jae     .stmt_copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r14 + rcx*8], rax
    inc     rcx
    jmp     .stmt_copy_loop
.stmt_copy_done:
    add     rsp, MAX_LIST_ARITY*8

    mov     rdi, AST_FUNC_BLOCK
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    mov     [rax + AST_D_OFF], r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.too_many_decls:
    mov     rsi, msg_too_many_decls
    mov     rdx, msg_too_many_decls_len
    call    report_parse_error
.too_many_fb_stmts:
    mov     rsi, msg_too_many_stmts
    mov     rdx, msg_too_many_stmts_len
    call    report_parse_error
