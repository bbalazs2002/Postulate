; Postulate Stage 0 -- top-level declaration parser (function / struct /
; extern function / program). See docs/postulate_stage0_parser_spec.md.
;
; `function` and `extern_decl` share the exact grammar substring
; identifier "(" params? ")" -- factored out as parse_signature / a shared
; AST_SIGNATURE node, rather than duplicating the params-list parsing
; twice. See the plan/spec for why a signature node is needed at all
; (name + params already costs 4 of the 4 generic node fields, leaving
; nothing for return_type/body -- a plain AST_FUNCTION node can't hold all
; of it directly).

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"

extern tok_cur
extern parser_advance
extern parser_expect
extern report_parse_error
extern ast_alloc_node
extern ast_alloc_bytes
extern parse_type
extern parse_func_block

global parse_param
global parse_params
global parse_signature
global parse_return_type
global parse_function
global parse_extern_decl
global parse_field_decl
global parse_struct_decl
global parse_top_level_decl
global parse_program

section .data
msg_expected_param_name:  db "expected parameter name"
msg_expected_param_name_len equ $ - msg_expected_param_name
msg_expected_func_name:  db "expected function name"
msg_expected_func_name_len equ $ - msg_expected_func_name
msg_expected_lparen:         db "expected '('"
msg_expected_lparen_len      equ $ - msg_expected_lparen
msg_expected_rparen:            db "expected ')'"
msg_expected_rparen_len         equ $ - msg_expected_rparen
msg_expected_colon:                db "expected ':'"
msg_expected_colon_len             equ $ - msg_expected_colon
msg_expected_semi:                    db "expected ';'"
msg_expected_semi_len                 equ $ - msg_expected_semi
msg_expected_func_kw:                    db "expected 'function' after 'extern'"
msg_expected_func_kw_len                 equ $ - msg_expected_func_kw
msg_expected_field_name:                    db "expected field name"
msg_expected_field_name_len                 equ $ - msg_expected_field_name
msg_expected_struct_name:                      db "expected struct name"
msg_expected_struct_name_len                   equ $ - msg_expected_struct_name
msg_expected_lbrace:                              db "expected '{'"
msg_expected_lbrace_len                           equ $ - msg_expected_lbrace
msg_too_many_elems:                                  db "too many elements in list"
msg_too_many_elems_len                               equ $ - msg_too_many_elems
msg_empty_struct_decl:                                  db "struct declaration requires at least one field"
msg_empty_struct_decl_len                               equ $ - msg_empty_struct_decl
msg_expected_top_level_decl:                               db "expected top-level declaration"
msg_expected_top_level_decl_len                            equ $ - msg_expected_top_level_decl
msg_empty_program:                                            db "program requires at least one top-level declaration"
msg_empty_program_len                                         equ $ - msg_empty_program

section .text

; ===========================================================================
; parse_param: param ::= identifier ":" type
; out: rax = AST_PARAM node ptr.
; ===========================================================================
parse_param:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .ok
    mov     rsi, msg_expected_param_name
    mov     rdx, msg_expected_param_name_len
    call    report_parse_error
.ok:
    push    r12                  ; name_offset
    push    r13                  ; name_len
    push    r14                  ; type ptr
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, TOK_COLON
    mov     rsi, msg_expected_colon
    mov     rdx, msg_expected_colon_len
    call    parser_expect
    call    parse_type
    mov     r14, rax
    mov     rdi, AST_PARAM
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_params: params ::= param ("," param)*  -- this routine handles the
; whole "params?" (zero-or-more) from the caller's point of view: an empty
; list (tok_cur already ')') is valid, no error. Same shape as
; expr_parser.asm's parse_call_args. Caller has already consumed '(' and
; will consume the closing ')'.
; out: rax = ptr to an arena array of node ptrs (0 if count==0), rdx = count.
; ===========================================================================
parse_params:
    push    r12                  ; count
    push    r13                  ; arena dest (set once count is known)
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RPAREN
    je      .empty
.elem_loop:
    call    parse_param
    mov     [rsp + r12*8], rax
    inc     r12
    cmp     r12, MAX_LIST_ARITY
    jae     .too_many
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_COMMA
    jne     .commit
    call    parser_advance
    jmp     .elem_loop
.commit:
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
    mov     rax, r13
    mov     rdx, r12
    add     rsp, MAX_LIST_ARITY*8
    pop     r13
    pop     r12
    ret
.empty:
    xor     rax, rax
    xor     rdx, rdx
    add     rsp, MAX_LIST_ARITY*8
    pop     r13
    pop     r12
    ret
.too_many:
    mov     rsi, msg_too_many_elems
    mov     rdx, msg_too_many_elems_len
    call    report_parse_error

; ===========================================================================
; parse_signature: identifier "(" params? ")" -- the shared prefix of
; `function` and `extern_decl`. out: rax = AST_SIGNATURE node ptr.
; ===========================================================================
parse_signature:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .have_name
    mov     rsi, msg_expected_func_name
    mov     rdx, msg_expected_func_name_len
    call    report_parse_error
.have_name:
    push    r12                  ; name_offset
    push    r13                  ; name_len
    push    r14                  ; params ptr
    push    r15                  ; param_count
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance

    mov     rdi, TOK_LPAREN
    mov     rsi, msg_expected_lparen
    mov     rdx, msg_expected_lparen_len
    call    parser_expect

    call    parse_params
    mov     r14, rax
    mov     r15, rdx

    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect

    mov     rdi, AST_SIGNATURE
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

; ===========================================================================
; parse_return_type: return_type ::= type | "void"
; out: rax = type node ptr, or 0 for "void" -- same "0 = absent" idiom
; already used for optional children elsewhere (STMT_RETURN's expr, DECL's
; init, STMT_IF's else). No AST node of its own.
; ===========================================================================
parse_return_type:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_VOID
    jne     .not_void
    call    parser_advance
    xor     rax, rax
    ret
.not_void:
    jmp     parse_type            ; tail call

; ===========================================================================
; parse_function: function ::= "function" identifier "(" params? ")" ":"
;                               return_type func_block
; out: rax = AST_FUNCTION node ptr.
; ===========================================================================
parse_function:
    push    r12                  ; signature ptr
    push    r13                  ; return_type ptr (0 = void)
    push    r14                  ; body ptr
    call    parser_advance                ; 'function'
    call    parse_signature
    mov     r12, rax

    mov     rdi, TOK_COLON
    mov     rsi, msg_expected_colon
    mov     rdx, msg_expected_colon_len
    call    parser_expect

    call    parse_return_type
    mov     r13, rax

    call    parse_func_block
    mov     r14, rax

    mov     rdi, AST_FUNCTION
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_extern_decl: extern_decl ::= "extern" "function" identifier
;                                     "(" params? ")" ":" return_type ";"
; out: rax = AST_EXTERN_DECL node ptr.
; ===========================================================================
parse_extern_decl:
    push    r12                  ; signature ptr
    push    r13                  ; return_type ptr (0 = void)
    call    parser_advance                ; 'extern'

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_FUNCTION
    je      .have_function_kw
    mov     rsi, msg_expected_func_kw
    mov     rdx, msg_expected_func_kw_len
    call    report_parse_error
.have_function_kw:
    call    parser_advance                ; 'function'
    call    parse_signature
    mov     r12, rax

    mov     rdi, TOK_COLON
    mov     rsi, msg_expected_colon
    mov     rdx, msg_expected_colon_len
    call    parser_expect

    call    parse_return_type
    mov     r13, rax

    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect

    mov     rdi, AST_EXTERN_DECL
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_field_decl: field_decl ::= identifier ":" type ";"
; out: rax = AST_FIELD_DECL node ptr.
; ===========================================================================
parse_field_decl:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .ok
    mov     rsi, msg_expected_field_name
    mov     rdx, msg_expected_field_name_len
    call    report_parse_error
.ok:
    push    r12                  ; name_offset
    push    r13                  ; name_len
    push    r14                  ; type ptr
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, TOK_COLON
    mov     rsi, msg_expected_colon
    mov     rdx, msg_expected_colon_len
    call    parser_expect
    call    parse_type
    mov     r14, rax
    mov     rdi, TOK_SEMI
    mov     rsi, msg_expected_semi
    mov     rdx, msg_expected_semi_len
    call    parser_expect
    mov     rdi, AST_FIELD_DECL
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; parse_struct_decl: struct_decl ::= "struct" identifier "{" field_decl+ "}"
; field_decl+ (>=1, no comma separator -- each field self-terminates with
; ';') -- check-empty-up-front with a dedicated message, same one-or-more
; shape as expr_parser.asm's parse_array_literal/parse_struct_literal.
; out: rax = AST_STRUCT_DECL node ptr.
; ===========================================================================
parse_struct_decl:
    push    r12                  ; name_offset
    push    r13                  ; name_len
    push    r14                  ; count
    push    r15                  ; arena dest
    call    parser_advance                ; 'struct'

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .have_name
    mov     rsi, msg_expected_struct_name
    mov     rdx, msg_expected_struct_name_len
    call    report_parse_error
.have_name:
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance

    mov     rdi, TOK_LBRACE
    mov     rsi, msg_expected_lbrace
    mov     rdx, msg_expected_lbrace_len
    call    parser_expect

    sub     rsp, MAX_LIST_ARITY*8
    xor     r14, r14

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    jne     .field_loop
    mov     rsi, msg_empty_struct_decl
    mov     rdx, msg_empty_struct_decl_len
    call    report_parse_error
.field_loop:
    call    parse_field_decl
    mov     [rsp + r14*8], rax
    inc     r14
    cmp     r14, MAX_LIST_ARITY
    jae     .too_many
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    jne     .field_loop
.commit:
    call    parser_advance                ; '}'
    mov     rdi, r14
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r15, rax
    xor     rcx, rcx
.copy_loop:
    cmp     rcx, r14
    jae     .copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r15 + rcx*8], rax
    inc     rcx
    jmp     .copy_loop
.copy_done:
    add     rsp, MAX_LIST_ARITY*8
    mov     rdi, AST_STRUCT_DECL
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r15
    mov     [rax + AST_D_OFF], r14
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.too_many:
    mov     rsi, msg_too_many_elems
    mov     rdx, msg_too_many_elems_len
    call    report_parse_error

; ===========================================================================
; parse_top_level_decl: top_level_decl ::= function | struct_decl | extern_decl
; Pure dispatcher, tail calls only -- no registers to save. Unlike
; parse_stmt, there is no lower-precedence rule to fall through to on a
; mismatch, so this needs its own explicit error message.
; ===========================================================================
parse_top_level_decl:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_KW_FUNCTION
    je      parse_function
    cmp     rax, TOK_KW_STRUCT
    je      parse_struct_decl
    cmp     rax, TOK_KW_EXTERN
    je      parse_extern_decl
    mov     rsi, msg_expected_top_level_decl
    mov     rdx, msg_expected_top_level_decl_len
    jmp     report_parse_error

; ===========================================================================
; parse_program: program ::= top_level_decl+ -- check-empty-up-front with a
; dedicated message, same one-or-more shape as parse_struct_decl's field
; list. Does NOT consume the trailing EOF itself -- the driver's own
; parser_expect(TOK_EOF, ...) post-check handles that uniformly, same as
; every other directive.
; out: rax = AST_PROGRAM node ptr.
; ===========================================================================
parse_program:
    push    r12                  ; count
    push    r13                  ; arena dest
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_EOF
    jne     .decl_loop
    mov     rsi, msg_empty_program
    mov     rdx, msg_empty_program_len
    call    report_parse_error
.decl_loop:
    call    parse_top_level_decl
    mov     [rsp + r12*8], rax
    inc     r12
    cmp     r12, MAX_LIST_ARITY
    jae     .too_many
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_EOF
    jne     .decl_loop
.commit:
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
    mov     rdi, AST_PROGRAM
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r13
    mov     [rax + AST_B_OFF], r12
    pop     r13
    pop     r12
    ret
.too_many:
    mov     rsi, msg_too_many_elems
    mov     rdx, msg_too_many_elems_len
    call    report_parse_error
