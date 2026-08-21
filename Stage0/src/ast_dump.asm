; Postulate Stage 0 -- AST -> S-expression dump.
; See docs/postulate_stage0_parser_spec.md section 10.
;
; Single-line, fully-parenthesized S-expressions, re-slicing source text via
; offset/length wherever possible (the lexer's own "offset+length, never a
; copied spelling table" convention).

%include "tokens.inc"
%include "ast.inc"
%include "runtime.inc"

extern parser_src_buf

global dump_type
global dump_expr
global dump_stmt
global dump_decl
global dump_func_block
global emit_dec

section .data
lp_base:  db "(base "
lp_base_len equ $ - lp_base
lp_ptr:   db "(ptr "
lp_ptr_len equ $ - lp_ptr
lp_array: db "(array "
lp_array_len equ $ - lp_array
rparen:   db ")"
space:    db " "

lp_int:   db "(int "
lp_int_len equ $ - lp_int
lp_bool_true:  db "(bool true)"
lp_bool_true_len equ $ - lp_bool_true
lp_bool_false: db "(bool false)"
lp_bool_false_len equ $ - lp_bool_false
lp_null:  db "(null)"
lp_null_len equ $ - lp_null
lp_ident: db "(ident "
lp_ident_len equ $ - lp_ident
lp_unary: db "(unary "
lp_unary_len equ $ - lp_unary
lp_binary: db "(binary "
lp_binary_len equ $ - lp_binary
lp_index: db "(index "
lp_index_len equ $ - lp_index
lp_field: db "(field "
lp_field_len equ $ - lp_field
lp_call:  db "(call "
lp_call_len equ $ - lp_call
lp_struct: db "(struct "
lp_struct_len equ $ - lp_struct
lp_array_lit: db "(array_lit"
lp_array_lit_len equ $ - lp_array_lit

lp_assign:    db "(assign"
lp_assign_len equ $ - lp_assign
lp_expr_stmt: db "(expr_stmt "
lp_expr_stmt_len equ $ - lp_expr_stmt
lp_pair:      db "(pair "
lp_pair_len equ $ - lp_pair
lp_if:        db "(if "
lp_if_len equ $ - lp_if
lp_while:     db "(while "
lp_while_len equ $ - lp_while
lp_return:    db "(return"
lp_return_len equ $ - lp_return
lp_block:     db "(block"
lp_block_len equ $ - lp_block
lp_decl_mut:   db "(decl_mut "
lp_decl_mut_len equ $ - lp_decl_mut
lp_decl_const: db "(decl_const "
lp_decl_const_len equ $ - lp_decl_const
lp_func_block: db "(func_block "
lp_func_block_len equ $ - lp_func_block
lp_decls:      db "(decls"
lp_decls_len equ $ - lp_decls
lp_stmts:      db "(stmts"
lp_stmts_len equ $ - lp_stmts

; operator symbol spellings, indexed by (kind - TOK_ASSIGN), matching
; TOK_ASSIGN..TOK_PIPE's contiguous order in tokens.inc (60-79)
sym_assign:  db ":="
sym_assign_len equ $ - sym_assign
sym_eq:      db "=="
sym_eq_len equ $ - sym_eq
sym_ne:      db "!="
sym_ne_len equ $ - sym_ne
sym_le:      db "<="
sym_le_len equ $ - sym_le
sym_ge:      db ">="
sym_ge_len equ $ - sym_ge
sym_shl:     db "<<"
sym_shl_len equ $ - sym_shl
sym_shr:     db ">>"
sym_shr_len equ $ - sym_shr
sym_andand:  db "&&"
sym_andand_len equ $ - sym_andand
sym_oror:    db "||"
sym_oror_len equ $ - sym_oror
sym_bang:    db "!"
sym_bang_len equ $ - sym_bang
sym_minus:   db "-"
sym_minus_len equ $ - sym_minus
sym_star:    db "*"
sym_star_len equ $ - sym_star
sym_amp:     db "&"
sym_amp_len equ $ - sym_amp
sym_slash:   db "/"
sym_slash_len equ $ - sym_slash
sym_percent: db "%"
sym_percent_len equ $ - sym_percent
sym_plus:    db "+"
sym_plus_len equ $ - sym_plus
sym_lt:      db "<"
sym_lt_len equ $ - sym_lt
sym_gt:      db ">"
sym_gt_len equ $ - sym_gt
sym_caret:   db "^"
sym_caret_len equ $ - sym_caret
sym_pipe:    db "|"
sym_pipe_len equ $ - sym_pipe

op_symbol_labels:
    dq sym_assign, sym_assign_len
    dq sym_eq, sym_eq_len
    dq sym_ne, sym_ne_len
    dq sym_le, sym_le_len
    dq sym_ge, sym_ge_len
    dq sym_shl, sym_shl_len
    dq sym_shr, sym_shr_len
    dq sym_andand, sym_andand_len
    dq sym_oror, sym_oror_len
    dq sym_bang, sym_bang_len
    dq sym_minus, sym_minus_len
    dq sym_star, sym_star_len
    dq sym_amp, sym_amp_len
    dq sym_slash, sym_slash_len
    dq sym_percent, sym_percent_len
    dq sym_plus, sym_plus_len
    dq sym_lt, sym_lt_len
    dq sym_gt, sym_gt_len
    dq sym_caret, sym_caret_len
    dq sym_pipe, sym_pipe_len

section .text

; ===========================================================================
; dump_type: in rdi = AST_TY_* node ptr; appends its S-expression to out_buf
; via emit_str. callee-saved used: rbx (node ptr, survives recursive calls).
; ===========================================================================
dump_type:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]

    cmp     rax, AST_TY_BASE
    je      .base
    cmp     rax, AST_TY_POINTER
    je      .pointer
    cmp     rax, AST_TY_ARRAY
    je      .array
    pop     rbx
    ret                          ; unknown kind: defensive no-op

.base:
    mov     rsi, lp_base
    mov     rdx, lp_base_len
    call    emit_str
    mov     rax, [rbx + AST_B_OFF]   ; name_offset
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_C_OFF]   ; name_len
    call    emit_str
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.pointer:
    mov     rsi, lp_ptr
    mov     rdx, lp_ptr_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_type
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.array:
    mov     rsi, lp_array
    mov     rdx, lp_array_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_type
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rax, [rbx + AST_B_OFF]
    call    emit_dec
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_expr: in rdi = AST_EX_* node ptr; appends its S-expression to out_buf
; via emit_str. callee-saved used: rbx (node ptr, survives recursive calls).
; AST_EX_CALL / AST_EX_STRUCT_LIT / AST_EX_ARRAY_LIT / AST_FIELD_INIT are
; added in a later step alongside the variable-arity list parsing.
; ===========================================================================
dump_expr:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]

    cmp     rax, AST_EX_INT
    je      .int
    cmp     rax, AST_EX_BOOL
    je      .bool
    cmp     rax, AST_EX_NULL
    je      .null
    cmp     rax, AST_EX_IDENT
    je      .ident
    cmp     rax, AST_EX_UNARY
    je      .unary
    cmp     rax, AST_EX_BINARY
    je      .binary
    cmp     rax, AST_EX_INDEX
    je      .index
    cmp     rax, AST_EX_FIELD
    je      .field
    cmp     rax, AST_EX_CALL
    je      .call
    cmp     rax, AST_EX_STRUCT_LIT
    je      .struct_lit
    cmp     rax, AST_EX_ARRAY_LIT
    je      .array_lit
    pop     rbx
    ret                          ; unknown kind: defensive no-op

.int:
    mov     rsi, lp_int
    mov     rdx, lp_int_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    call    emit_dec
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.bool:
    mov     rax, [rbx + AST_A_OFF]
    cmp     rax, 0
    jne     .bool_true
    mov     rsi, lp_bool_false
    mov     rdx, lp_bool_false_len
    call    emit_str
    pop     rbx
    ret
.bool_true:
    mov     rsi, lp_bool_true
    mov     rdx, lp_bool_true_len
    call    emit_str
    pop     rbx
    ret

.null:
    mov     rsi, lp_null
    mov     rdx, lp_null_len
    call    emit_str
    pop     rbx
    ret

.ident:
    mov     rsi, lp_ident
    mov     rdx, lp_ident_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_B_OFF]
    call    emit_str
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.unary:
    mov     rsi, lp_unary
    mov     rdx, lp_unary_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    call    emit_op_symbol
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.binary:
    mov     rsi, lp_binary
    mov     rdx, lp_binary_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    call    emit_op_symbol
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_C_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.index:
    mov     rsi, lp_index
    mov     rdx, lp_index_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.field:
    mov     rsi, lp_field
    mov     rdx, lp_field_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rax, [rbx + AST_B_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_C_OFF]
    call    emit_str
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.call:
    mov     rsi, lp_call
    mov     rdx, lp_call_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; callee
    call    dump_expr
    mov     rdi, [rbx + AST_B_OFF]   ; args ptr
    mov     rsi, [rbx + AST_C_OFF]   ; arg_count
    mov     rcx, dump_expr
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.struct_lit:
    mov     rsi, lp_struct
    mov     rdx, lp_struct_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]   ; type name_offset
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_B_OFF]   ; type name_len
    call    emit_str
    mov     rdi, [rbx + AST_C_OFF]   ; fields ptr
    mov     rsi, [rbx + AST_D_OFF]   ; field_count
    mov     rcx, dump_field_init
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.array_lit:
    mov     rsi, lp_array_lit
    mov     rdx, lp_array_lit_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; elems ptr
    mov     rsi, [rbx + AST_B_OFF]   ; elem_count
    mov     rcx, dump_expr
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_field_init: in rdi = AST_FIELD_INIT node ptr; appends "(field <name>
; <value>)". Only ever reached via dump_node_list from a struct_literal's
; field array -- not part of dump_expr's own kind dispatch.
; ===========================================================================
dump_field_init:
    push    rbx
    mov     rbx, rdi
    mov     rsi, lp_field
    mov     rdx, lp_field_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_B_OFF]
    call    emit_str
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_C_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_node_list: in rdi = array ptr, rsi = count, rcx = per-element dump
; routine ptr. Emits a leading space + a call to that routine per element --
; the caller supplies its own opening/closing parens. Shared by AST_EX_CALL
; (dump_expr), AST_EX_STRUCT_LIT (dump_field_init), and AST_EX_ARRAY_LIT
; (dump_expr) -- one representation (ptr, count) to an arena array of node
; ptrs, one consumer routine.
; ===========================================================================
dump_node_list:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi             ; array ptr
    mov     r12, rsi             ; count
    mov     r13, rcx             ; dump routine ptr
    xor     r14, r14             ; index
.loop:
    cmp     r14, r12
    jae     .done
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + r14*8]
    call    r13
    inc     r14
    jmp     .loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; emit_op_symbol: in rax = TOK_* op kind (ASSIGN..PIPE range); appends its
; symbol spelling via the op_symbol_labels table.
; ===========================================================================
emit_op_symbol:
    mov     rcx, rax
    sub     rcx, TOK_ASSIGN
    shl     rcx, 4              ; byte offset = index * 16
    mov     rsi, [op_symbol_labels + rcx]
    mov     rdx, [op_symbol_labels + rcx + 8]
    jmp     emit_str

; ===========================================================================
; dump_stmt: in rdi = AST_STMT_* node ptr; appends its S-expression via
; emit_str. callee-saved used: rbx. This is AST_BLOCK's per-element dump
; routine (parallel to how dump_expr serves AST_EX_CALL/AST_EX_ARRAY_LIT).
; ===========================================================================
dump_stmt:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]

    cmp     rax, AST_STMT_ASSIGN
    je      .assign
    cmp     rax, AST_STMT_EXPR
    je      .expr_stmt
    cmp     rax, AST_STMT_IF
    je      .if_stmt
    cmp     rax, AST_STMT_WHILE
    je      .while_stmt
    cmp     rax, AST_STMT_RETURN
    je      .return_stmt
    pop     rbx
    ret                          ; unknown kind: defensive no-op

.if_stmt:
    mov     rsi, lp_if
    mov     rdx, lp_if_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; cond
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]   ; then_block
    call    dump_block
    mov     rax, [rbx + AST_C_OFF]   ; else_block, 0 if absent
    cmp     rax, 0
    je      .if_no_else
    mov     rsi, space
    mov     rdx, 1
    call    emit_str                 ; clobbers rax (caller-saved) -- re-read below
    mov     rdi, [rbx + AST_C_OFF]
    call    dump_block
.if_no_else:
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.while_stmt:
    mov     rsi, lp_while
    mov     rdx, lp_while_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; cond
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]   ; body
    call    dump_block
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.return_stmt:
    mov     rsi, lp_return
    mov     rdx, lp_return_len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]   ; expr, 0 if absent
    cmp     rax, 0
    je      .return_no_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str                 ; clobbers rax (caller-saved) -- re-read below
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_expr
.return_no_expr:
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.assign:
    mov     rsi, lp_assign
    mov     rdx, lp_assign_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; pairs ptr
    mov     rsi, [rbx + AST_B_OFF]   ; pair_count
    mov     rcx, dump_assign_pair
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

.expr_stmt:
    mov     rsi, lp_expr_stmt
    mov     rdx, lp_expr_stmt_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_block: in rdi = AST_BLOCK node ptr; appends "(block <stmt0> ...)".
; Internal helper (parallel to dump_field_init/dump_assign_pair), used by
; dump_stmt's if/while cases.
; ===========================================================================
dump_block:
    push    rbx
    mov     rbx, rdi
    mov     rsi, lp_block
    mov     rdx, lp_block_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; stmts ptr
    mov     rsi, [rbx + AST_B_OFF]   ; stmt_count
    mov     rcx, dump_stmt
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_decl: in rdi = AST_DECL_MUT/AST_DECL_CONST node ptr; appends
; "(decl_mut <name> <type>)" or "(decl_const <name> <type>)", with a
; trailing "<init>" only if present.
; ===========================================================================
dump_decl:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_DECL_MUT
    je      .mut
    cmp     rax, AST_DECL_CONST
    je      .const
    pop     rbx
    ret                          ; unknown kind: defensive no-op
.mut:
    mov     rsi, lp_decl_mut
    mov     rdx, lp_decl_mut_len
    call    emit_str
    jmp     .common
.const:
    mov     rsi, lp_decl_const
    mov     rdx, lp_decl_const_len
    call    emit_str
.common:
    mov     rax, [rbx + AST_A_OFF]   ; name_offset
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [rbx + AST_B_OFF]   ; name_len
    call    emit_str
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_C_OFF]   ; type ptr
    call    dump_type
    mov     rax, [rbx + AST_D_OFF]   ; init, 0 if absent
    cmp     rax, 0
    je      .no_init
    mov     rsi, space
    mov     rdx, 1
    call    emit_str                 ; clobbers rax -- re-read below
    mov     rdi, [rbx + AST_D_OFF]
    call    dump_expr
.no_init:
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_func_block: in rdi = AST_FUNC_BLOCK node ptr; appends "(func_block
; (decls <decl0> ...) (stmts <stmt0> ...))" -- its own two-list dump,
; calling dump_node_list twice (once with dump_decl, once with dump_stmt).
; ===========================================================================
dump_func_block:
    push    rbx
    mov     rbx, rdi
    mov     rsi, lp_func_block
    mov     rdx, lp_func_block_len
    call    emit_str

    mov     rsi, lp_decls
    mov     rdx, lp_decls_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]   ; decls ptr
    mov     rsi, [rbx + AST_B_OFF]   ; decl_count
    mov     rcx, dump_decl
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str

    mov     rsi, space
    mov     rdx, 1
    call    emit_str

    mov     rsi, lp_stmts
    mov     rdx, lp_stmts_len
    call    emit_str
    mov     rdi, [rbx + AST_C_OFF]   ; stmts ptr
    mov     rsi, [rbx + AST_D_OFF]   ; stmt_count
    mov     rcx, dump_stmt
    call    dump_node_list
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str

    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; dump_assign_pair: in rdi = AST_ASSIGN_PAIR node ptr; appends "(pair
; <lvalue> <rhs>)". Only ever reached via dump_node_list, parallel to
; dump_field_init.
; ===========================================================================
dump_assign_pair:
    push    rbx
    mov     rbx, rdi
    mov     rsi, lp_pair
    mov     rdx, lp_pair_len
    call    emit_str
    mov     rdi, [rbx + AST_A_OFF]
    call    dump_expr
    mov     rsi, space
    mov     rdx, 1
    call    emit_str
    mov     rdi, [rbx + AST_B_OFF]
    call    dump_expr
    mov     rsi, rparen
    mov     rdx, 1
    call    emit_str
    pop     rbx
    ret

; ===========================================================================
; emit_dec: in rax = unsigned value; appends decimal ASCII via emit_str.
; Deliberately parallels runtime.asm's err_append_dec (same digit-conversion
; logic, targeting the stdout-buffered emit_str instead of the stderr
; one-shot err_append_str) -- see spec section 10's noted duplication.
; ===========================================================================
emit_dec:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rsp
    lea     r12, [rbx + 32]
    mov     r13, rax
    test    r13, r13
    jnz     .loop
    dec     r12
    mov     byte [r12], '0'
    jmp     .emit
.loop:
    test    r13, r13
    jz      .emit
    xor     rdx, rdx
    mov     rax, r13
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    dec     r12
    mov     [r12], dl
    mov     r13, rax
    jmp     .loop
.emit:
    mov     rsi, r12
    lea     rdx, [rbx + 32]
    sub     rdx, r12
    call    emit_str
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret
