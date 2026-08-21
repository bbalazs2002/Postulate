; Postulate Stage 0 -- expression parser.
; See docs/postulate_stage0_parser_spec.md section 7.
;
; One grammar rule = one routine, direct transcription of the EBNF
; precedence chain (not Pratt/precedence-climbing) -- matches the lexer's
; own "auditability over cleverness" precedent.
;
; Every binary-level routine below uses r12 (and r13 for the "current
; operator" when the op-set has more than one member) as its own
; push/pop-protected local accumulator -- safe under arbitrarily deep
; recursion into tighter-binding levels, since each routine's own
; push/pop creates a fresh stack-nested copy regardless of what any
; nested call does with the physical register.
;
; Variable-arity lists (call args, array-literal elements, struct-literal
; field inits) are staged on the machine call stack (MAX_LIST_ARITY*8 bytes)
; while parsing, then copied into an exact-size arena array once the count
; is known -- see spec section 8. Native call-stack recursion is what makes
; this safe for nested lists (e.g. an array-literal element that is itself
; a call with its own argument list): each nested list-parsing call gets
; its own fresh rsp-relative scratch region for free.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"

extern tok_cur
extern parser_advance
extern parser_peek
extern parser_expect
extern report_parse_error
extern ast_alloc_node
extern ast_alloc_bytes
extern ast_build_unary
extern ast_build_binary

global parse_expr
global parse_logic_or
global parse_logic_and
global parse_comparison
global parse_bit_or
global parse_bit_xor
global parse_bit_and
global parse_shift
global parse_additive
global parse_multiplicative
global parse_unary
global parse_postfix
global parse_primary
global parse_call_args
global parse_array_literal
global parse_struct_literal
global parse_field_init

section .data
msg_expected_expr:       db "expected expression"
msg_expected_expr_len    equ $ - msg_expected_expr
msg_expected_rparen:        db "expected ')'"
msg_expected_rparen_len     equ $ - msg_expected_rparen
msg_expected_rbracket:         db "expected ']'"
msg_expected_rbracket_len      equ $ - msg_expected_rbracket
msg_expected_ident:               db "expected identifier after '.'"
msg_expected_ident_len            equ $ - msg_expected_ident
msg_expected_rbrace:                 db "expected '}'"
msg_expected_rbrace_len              equ $ - msg_expected_rbrace
msg_too_many_elems:                     db "too many elements in list"
msg_too_many_elems_len                  equ $ - msg_too_many_elems
msg_empty_array_lit:                       db "array literal requires at least one element"
msg_empty_array_lit_len                    equ $ - msg_empty_array_lit
msg_empty_struct_lit:                         db "struct literal requires at least one field"
msg_empty_struct_lit_len                      equ $ - msg_empty_struct_lit
msg_expected_field_name:                         db "expected field name"
msg_expected_field_name_len                      equ $ - msg_expected_field_name
msg_expected_assign:                                db "expected ':='"
msg_expected_assign_len                             equ $ - msg_expected_assign

section .text

; ===========================================================================
; parse_expr: expr ::= logic_or -- a trivial alias, kept as its own routine
; purely for 1:1 traceability against the grammar's own rule names.
; ===========================================================================
parse_expr:
    jmp     parse_logic_or

parse_logic_or:
    push    r12
    call    parse_logic_and
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_OROR
    jne     .done
    call    parser_advance
    call    parse_logic_and
    mov     rdi, TOK_OROR
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_logic_and:
    push    r12
    call    parse_comparison
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_ANDAND
    jne     .done
    call    parser_advance
    call    parse_comparison
    mov     rdi, TOK_ANDAND
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

; comparison ::= bit_or (("==" | "!=" | "<" | ">" | "<=" | ">=") bit_or)?
; NOTE: this is `if`, not `while` -- comparison is deliberately non-
; chainable (main spec section 4). A second comparison operator
; immediately following (e.g. "a < b < c") is left unconsumed on purpose;
; it surfaces as a syntax error one level up, at the driver's post-parse
; "expected end of input" check. This is a literal, intentional
; transcription of the grammar's `?` -- not a missing loop.
parse_comparison:
    push    r12
    call    parse_bit_or
    mov     r12, rax
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_EQ
    je      .has_cmp
    cmp     rax, TOK_NE
    je      .has_cmp
    cmp     rax, TOK_LT
    je      .has_cmp
    cmp     rax, TOK_GT
    je      .has_cmp
    cmp     rax, TOK_LE
    je      .has_cmp
    cmp     rax, TOK_GE
    je      .has_cmp
    jmp     .done
.has_cmp:
    push    r13
    mov     r13, rax
    call    parser_advance
    call    parse_bit_or
    mov     rdi, r13
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    pop     r13
.done:
    mov     rax, r12
    pop     r12
    ret

parse_bit_or:
    push    r12
    call    parse_bit_xor
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_PIPE
    jne     .done
    call    parser_advance
    call    parse_bit_xor
    mov     rdi, TOK_PIPE
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_bit_xor:
    push    r12
    call    parse_bit_and
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_CARET
    jne     .done
    call    parser_advance
    call    parse_bit_and
    mov     rdi, TOK_CARET
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_bit_and:
    push    r12
    call    parse_shift
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_AMP
    jne     .done
    call    parser_advance
    call    parse_shift
    mov     rdi, TOK_AMP
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_shift:
    push    r12
    call    parse_additive
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_SHL
    je      .match
    cmp     rax, TOK_SHR
    je      .match
    jmp     .done
.match:
    push    r13
    mov     r13, rax
    call    parser_advance
    call    parse_additive
    mov     rdi, r13
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    pop     r13
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_additive:
    push    r12
    call    parse_multiplicative
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_PLUS
    je      .match
    cmp     rax, TOK_MINUS
    je      .match
    jmp     .done
.match:
    push    r13
    mov     r13, rax
    call    parser_advance
    call    parse_multiplicative
    mov     rdi, r13
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    pop     r13
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

parse_multiplicative:
    push    r12
    call    parse_unary
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_STAR
    je      .match
    cmp     rax, TOK_SLASH
    je      .match
    cmp     rax, TOK_PERCENT
    je      .match
    jmp     .done
.match:
    push    r13
    mov     r13, rax
    call    parser_advance
    call    parse_unary
    mov     rdi, r13
    mov     rsi, r12
    mov     rdx, rax
    call    ast_build_binary
    mov     r12, rax
    pop     r13
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

; unary ::= ("!" | "-" | "*" | "&") unary | postfix
; Right-associative prefix chain: recurses into itself, not parse_postfix,
; so "!!x" / "**p" chain correctly.
parse_unary:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_BANG
    je      .is_unary
    cmp     rax, TOK_MINUS
    je      .is_unary
    cmp     rax, TOK_STAR
    je      .is_unary
    cmp     rax, TOK_AMP
    je      .is_unary
    jmp     parse_postfix        ; tail call
.is_unary:
    push    r12
    mov     r12, rax             ; op
    call    parser_advance
    call    parse_unary          ; recursive
    mov     rdi, r12
    mov     rsi, rax
    call    ast_build_unary
    pop     r12
    ret

; postfix ::= primary postfix_op*  (postfix_op: "[" expr "]" | "." identifier
; | "(" args? ")")
parse_postfix:
    push    r12
    call    parse_primary
    mov     r12, rax
.loop:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_LBRACKET
    je      .index
    cmp     rax, TOK_DOT
    je      .field
    cmp     rax, TOK_LPAREN
    je      .call
    jmp     .done
.call:
    call    parser_advance          ; consume '('
    call    parse_call_args         ; rax = args ptr, rdx = arg_count
    push    r13
    push    r14
    mov     r13, rax
    mov     r14, rdx
    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect
    mov     rdi, AST_EX_CALL
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12   ; callee -- the postfix chain so far
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    mov     r12, rax
    pop     r14
    pop     r13
    jmp     .loop
.index:
    call    parser_advance
    call    parse_expr
    push    r13
    mov     r13, rax
    mov     rdi, TOK_RBRACKET
    mov     rsi, msg_expected_rbracket
    mov     rdx, msg_expected_rbracket_len
    call    parser_expect
    mov     rdi, AST_EX_INDEX
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     r12, rax
    pop     r13
    jmp     .loop
.field:
    call    parser_advance
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .field_ok
    mov     rsi, msg_expected_ident
    mov     rdx, msg_expected_ident_len
    call    report_parse_error
.field_ok:
    push    r13
    push    r14
    mov     r13, [tok_cur + TOK_OFFSET_OFF]
    mov     r14, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, AST_EX_FIELD
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    mov     r12, rax
    pop     r14
    pop     r13
    jmp     .loop
.done:
    mov     rax, r12
    pop     r12
    ret

; primary ::= struct_literal | array_literal | identifier | literal | "(" expr ")"
parse_primary:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .ident_or_struct
    cmp     rax, TOK_INT
    je      .int
    cmp     rax, TOK_KW_TRUE
    je      .true
    cmp     rax, TOK_KW_FALSE
    je      .false
    cmp     rax, TOK_KW_NULL
    je      .null
    cmp     rax, TOK_LPAREN
    je      .paren
    cmp     rax, TOK_LBRACE
    je      .array_lit
    mov     rsi, msg_expected_expr
    mov     rdx, msg_expected_expr_len
    jmp     report_parse_error
; TOK_IDENT vs struct_literal: peek one further token (does not consume) --
; if it's '{', this is a struct_literal (identifier "{" ...), not a bare
; identifier. Zero backtracking, exactly the 2-token lookahead the buffer
; was designed for.
.ident_or_struct:
    call    parser_peek
    mov     rax, [rax + TOK_KIND_OFF]
    cmp     rax, TOK_LBRACE
    je      .struct_lit
    ; r12/r13 are treated as callee-saved everywhere in this codebase -- push
    ; them even though no *existing* call site happened to need them to
    ; survive this particular leaf, since a caller further up the chain
    ; (e.g. a variable-arity pair/list loop) may hold live state in them
    ; across a nested call into parse_expr that bottoms out here.
    push    r12
    push    r13
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, AST_EX_IDENT
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    pop     r13
    pop     r12
    ret
.struct_lit:
    jmp     parse_struct_literal     ; tail call -- consumes ident + '{'..'}' itself
.array_lit:
    jmp     parse_array_literal      ; tail call -- consumes '{'..'}' itself
.int:
    push    r12
    mov     r12, [tok_cur + TOK_VALUE_OFF]
    call    parser_advance
    mov     rdi, AST_EX_INT
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    pop     r12
    ret
.true:
    call    parser_advance
    mov     rdi, AST_EX_BOOL
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], 1
    ret
.false:
    call    parser_advance
    mov     rdi, AST_EX_BOOL
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], 0
    ret
.null:
    call    parser_advance
    mov     rdi, AST_EX_NULL
    call    ast_alloc_node
    ret
.paren:
    call    parser_advance
    call    parse_expr
    push    r12
    mov     r12, rax
    mov     rdi, TOK_RPAREN
    mov     rsi, msg_expected_rparen
    mov     rdx, msg_expected_rparen_len
    call    parser_expect
    mov     rax, r12
    pop     r12
    ret

; ===========================================================================
; parse_call_args: args ::= expr_list?  (zero args is valid). Caller
; (parse_postfix) has already consumed '(' and will consume the closing ')'.
; out: rax = ptr to an arena array of node ptrs (0 if count==0), rdx = count.
; ===========================================================================
parse_call_args:
    push    r12                  ; count
    push    r13                  ; arena dest (set once count is known)
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RPAREN
    je      .empty
.elem_loop:
    call    parse_expr
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
; parse_array_literal: array_literal ::= "{" expr_list "}" (>=1 element --
; the grammar has no "?" here, unlike call args). Caller (parse_primary)
; has not consumed anything yet; this routine consumes '{'...'}' itself.
; out: rax = AST_EX_ARRAY_LIT node.
; ===========================================================================
parse_array_literal:
    push    r12                  ; count
    push    r13                  ; arena dest
    call    parser_advance       ; consume '{'
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    jne     .elem_loop
    mov     rsi, msg_empty_array_lit
    mov     rdx, msg_empty_array_lit_len
    call    report_parse_error
.elem_loop:
    call    parse_expr
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
    mov     rdi, TOK_RBRACE
    mov     rsi, msg_expected_rbrace
    mov     rdx, msg_expected_rbrace_len
    call    parser_expect
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
    mov     rdi, AST_EX_ARRAY_LIT
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

; ===========================================================================
; parse_struct_literal: struct_literal ::= identifier "{" field_init
; ("," field_init)* "}" (>=1 field required). Caller (parse_primary) has
; peeked but not consumed anything -- this routine consumes the leading
; identifier and '{'...'}' itself.
; out: rax = AST_EX_STRUCT_LIT node.
; ===========================================================================
parse_struct_literal:
    push    r12                  ; count
    push    r13                  ; name_offset
    push    r14                  ; name_len
    push    r15                  ; arena dest
    mov     r13, [tok_cur + TOK_OFFSET_OFF]
    mov     r14, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance       ; consume the type-name identifier
    call    parser_advance       ; consume '{'
    sub     rsp, MAX_LIST_ARITY*8
    xor     r12, r12

    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_RBRACE
    jne     .field_loop
    mov     rsi, msg_empty_struct_lit
    mov     rdx, msg_empty_struct_lit_len
    call    report_parse_error
.field_loop:
    call    parse_field_init
    mov     [rsp + r12*8], rax
    inc     r12
    cmp     r12, MAX_LIST_ARITY
    jae     .too_many
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_COMMA
    jne     .commit
    call    parser_advance
    jmp     .field_loop
.commit:
    mov     rdi, TOK_RBRACE
    mov     rsi, msg_expected_rbrace
    mov     rdx, msg_expected_rbrace_len
    call    parser_expect
    mov     rdi, r12
    shl     rdi, 3
    call    ast_alloc_bytes
    mov     r15, rax
    xor     rcx, rcx
.copy_loop:
    cmp     rcx, r12
    jae     .copy_done
    mov     rax, [rsp + rcx*8]
    mov     [r15 + rcx*8], rax
    inc     rcx
    jmp     .copy_loop
.copy_done:
    add     rsp, MAX_LIST_ARITY*8
    mov     rdi, AST_EX_STRUCT_LIT
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r13
    mov     [rax + AST_B_OFF], r14
    mov     [rax + AST_C_OFF], r15
    mov     [rax + AST_D_OFF], r12
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
; parse_field_init: field_init ::= identifier ":=" expr
; out: rax = AST_FIELD_INIT node ptr.
; ===========================================================================
parse_field_init:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, TOK_IDENT
    je      .ok
    mov     rsi, msg_expected_field_name
    mov     rdx, msg_expected_field_name_len
    call    report_parse_error
.ok:
    push    r12
    push    r13
    push    r14
    mov     r12, [tok_cur + TOK_OFFSET_OFF]
    mov     r13, [tok_cur + TOK_LENGTH_OFF]
    call    parser_advance
    mov     rdi, TOK_ASSIGN
    mov     rsi, msg_expected_assign
    mov     rdx, msg_expected_assign_len
    call    parser_expect
    call    parse_expr
    mov     r14, rax
    mov     rdi, AST_FIELD_INIT
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    mov     [rax + AST_B_OFF], r13
    mov     [rax + AST_C_OFF], r14
    pop     r14
    pop     r13
    pop     r12
    ret
