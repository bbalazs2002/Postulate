; Postulate Stage 0 -- semantic analyzer: statement checks, extern
; whitelist validation, and check_program's top-level orchestration.
; See docs/postulate_stage0_semantics_spec.md.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern ast_alloc_node
extern bytes_equal
extern lookup_local
extern build_global_tables
extern build_local_table
extern resolve_all_types
extern check_expr
extern find_offset
extern is_valid_lvalue
extern types_equal
extern get_bool_type
extern is_bool_type
extern sema_report_begin
extern sema_report_finish
extern err_append_span
extern quote_char

global check_program
global check_stmt
global check_block
global check_func_block
global check_decl
global check_extern_whitelist

section .data
str_sys_read:  db "sys_read"
str_sys_write: db "sys_write"
str_sys_mmap:  db "sys_mmap"
str_sys_exit:  db "sys_exit"

msg_expected_bool:            db "expected 'bool'"
msg_expected_bool_len         equ $ - msg_expected_bool
msg_decl_init_type_mismatch:      db "declaration initializer type mismatch"
msg_decl_init_type_mismatch_len   equ $ - msg_decl_init_type_mismatch
msg_return_type_mismatch:            db "return expression type mismatch"
msg_return_type_mismatch_len         equ $ - msg_return_type_mismatch
msg_return_missing_value:               db "missing return value in a non-void function"
msg_return_missing_value_len            equ $ - msg_return_missing_value
msg_return_unexpected_value:                db "'void' function cannot return a value"
msg_return_unexpected_value_len             equ $ - msg_return_unexpected_value
msg_invalid_lvalue:                            db "invalid assignment target"
msg_invalid_lvalue_len                         equ $ - msg_invalid_lvalue
msg_const_reassignment:                           db "cannot assign to const '"
msg_const_reassignment_len                        equ $ - msg_const_reassignment
msg_assign_type_mismatch:                            db "assignment type mismatch"
msg_assign_type_mismatch_len                         equ $ - msg_assign_type_mismatch
msg_duplicate_assign_target:                            db "duplicate target in simultaneous assignment"
msg_duplicate_assign_target_len                         equ $ - msg_duplicate_assign_target
msg_missing_return_path:                                   db "function '"
msg_missing_return_path_len                                equ $ - msg_missing_return_path
msg_missing_return_path_2:                                     db "' may not return a value on every execution path"
msg_missing_return_path_2_len                                  equ $ - msg_missing_return_path_2
msg_extern_not_whitelisted:                                db "extern function '"
msg_extern_not_whitelisted_len                             equ $ - msg_extern_not_whitelisted
msg_extern_not_whitelisted_2:                                 db "' is not on the recognized syscall list"
msg_extern_not_whitelisted_2_len                              equ $ - msg_extern_not_whitelisted_2
msg_extern_signature_mismatch:                                   db "extern function '"
msg_extern_signature_mismatch_len                                equ $ - msg_extern_signature_mismatch
msg_extern_signature_mismatch_2:                                    db "' does not match its required signature"
msg_extern_signature_mismatch_2_len                                 equ $ - msg_extern_signature_mismatch_2

section .text

; ===========================================================================
; lvalue_equal: in rdi = expr node, rsi = expr node. out: rax = 1/0 --
; exact structural equality over IDENT/UNARY/INDEX/FIELD shapes only (any
; other kind, e.g. a non-lvalue-shaped index sub-expression, conservatively
; compares "not equal" -- no aliasing analysis, ld. plan/spec scope: this
; only catches syntactically-identical duplicate targets, e.g. "x := 1,
; x := 2;", not "arr[i] := 1, arr[j] := 2;" even if i == j at runtime).
; ===========================================================================
lvalue_equal:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx + AST_KIND_OFF]
    mov     rcx, [r12 + AST_KIND_OFF]
    cmp     rax, rcx
    jne     .no
    cmp     rax, AST_EX_IDENT
    je      .ident
    cmp     rax, AST_EX_UNARY
    je      .unary
    cmp     rax, AST_EX_INDEX
    je      .index
    cmp     rax, AST_EX_FIELD
    je      .field
    jmp     .no
.ident:
    mov     rdx, [rbx + AST_B_OFF]
    cmp     rdx, [r12 + AST_B_OFF]
    jne     .no
    mov     rdi, [parser_src_buf]
    add     rdi, [rbx + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, [r12 + AST_A_OFF]
    call    bytes_equal
    jmp     .done
.unary:
    mov     rdx, [rbx + AST_A_OFF]
    cmp     rdx, [r12 + AST_A_OFF]
    jne     .no
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, [r12 + AST_B_OFF]
    call    lvalue_equal
    jmp     .done
.index:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [r12 + AST_A_OFF]
    call    lvalue_equal
    cmp     rax, 0
    je      .no
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, [r12 + AST_B_OFF]
    call    lvalue_equal
    jmp     .done
.field:
    mov     rdx, [rbx + AST_C_OFF]
    cmp     rdx, [r12 + AST_C_OFF]
    jne     .no
    mov     rdi, [parser_src_buf]
    add     rdi, [rbx + AST_B_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, [r12 + AST_B_OFF]
    mov     rdx, [rbx + AST_C_OFF]
    call    bytes_equal
    cmp     rax, 0
    je      .no
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [r12 + AST_A_OFF]
    call    lvalue_equal
    jmp     .done
.no:
    xor     rax, rax
.done:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_const_reassignment: in rdi = lvalue node ptr. Reports "cannot
; assign to const" and never returns iff this lvalue chain reaches its
; base identifier WITHOUT ever passing through a "*" deref, and that base
; is const-declared (spec gap #3) -- write-through-pointer bypasses this
; regardless of the pointer binding's own const-ness.
; ===========================================================================
check_const_reassignment:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .check_base
    cmp     rax, AST_EX_INDEX
    je      .recurse_a
    cmp     rax, AST_EX_FIELD
    je      .recurse_a
    ret                                  ; UNARY(*) or anything else: a
                                          ; deref happened, or an already-
                                          ; rejected shape -- nothing to do
.recurse_a:
    mov     rdi, [rdi + AST_A_OFF]
    jmp     check_const_reassignment
.check_base:
    push    rbx
    mov     rbx, rdi
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    lookup_local
    cmp     rax, 0
    je      .ok                          ; defensive: check_expr already
                                          ; validates this resolves
    cmp     qword [rax + LTE_IS_CONST], 0
    je      .ok
    call    sema_report_begin
    mov     rsi, msg_const_reassignment
    mov     rdx, msg_const_reassignment_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    jmp     sema_report_finish
.ok:
    pop     rbx
    ret

; ===========================================================================
; check_decl: in rdi = AST_DECL_MUT/CONST ptr. If an init is present,
; checks it against the declared type.
; ===========================================================================
check_decl:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_D_OFF]      ; init, 0 if absent
    cmp     rax, 0
    je      .no_init
    mov     rdi, rax
    mov     rsi, [rbx + AST_C_OFF]
    call    check_expr
    mov     rdi, rax
    mov     rsi, [rbx + AST_C_OFF]
    call    types_equal
    cmp     rax, 0
    jne     .no_init
    call    sema_report_begin
    mov     rsi, msg_decl_init_type_mismatch
    mov     rdx, msg_decl_init_type_mismatch_len
    call    err_append_str
    mov     rdi, [rbx + AST_D_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.no_init:
    pop     rbx
    ret

; ===========================================================================
; check_block: in rdi = AST_BLOCK ptr, rsi = enclosing function's declared
; return type (0 = void). Checks every statement in it.
; ===========================================================================
check_block:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, [rbx + AST_A_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_B_OFF]      ; stmt_count
    xor     r15, r15
.loop:
    cmp     r15, r14
    jae     .done
    mov     rdi, [r13 + r15*8]
    mov     rsi, r12
    call    check_stmt
    inc     r15
    jmp     .loop
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_func_block: in rdi = AST_FUNC_BLOCK ptr, rsi = enclosing
; function's declared return type (0 = void). Checks every decl's init
; and every statement.
; ===========================================================================
check_func_block:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi

    mov     r13, [rbx + AST_A_OFF]      ; decls ptr
    mov     r14, [rbx + AST_B_OFF]      ; decl_count
    xor     r15, r15
.decl_loop:
    cmp     r15, r14
    jae     .decls_done
    mov     rdi, [r13 + r15*8]
    call    check_decl
    inc     r15
    jmp     .decl_loop
.decls_done:
    mov     r13, [rbx + AST_C_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_D_OFF]      ; stmt_count
    xor     r15, r15
.stmt_loop:
    cmp     r15, r14
    jae     .done
    mov     rdi, [r13 + r15*8]
    mov     rsi, r12
    call    check_stmt
    inc     r15
    jmp     .stmt_loop
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_stmt: in rdi = stmt node ptr, rsi = enclosing function's declared
; return type (0 = void). Reports a semantic error and never returns on
; any violation found along the way.
; ===========================================================================
check_stmt:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi
    mov     r12, rsi                    ; return_type
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
    jmp     .exit                        ; unreachable per grammar

.expr_stmt:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_expr
    jmp     .exit

.if_stmt:
    call    get_bool_type
    mov     r13, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    call    is_bool_type
    cmp     rax, 0
    jne     .if_cond_ok
    call    sema_report_begin
    mov     rsi, msg_expected_bool
    mov     rdx, msg_expected_bool_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.if_cond_ok:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r12
    call    check_block
    mov     rax, [rbx + AST_C_OFF]
    cmp     rax, 0
    je      .exit
    mov     rdi, rax
    mov     rsi, r12
    call    check_block
    jmp     .exit

.while_stmt:
    call    get_bool_type
    mov     r13, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    call    is_bool_type
    cmp     rax, 0
    jne     .while_cond_ok
    call    sema_report_begin
    mov     rsi, msg_expected_bool
    mov     rdx, msg_expected_bool_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.while_cond_ok:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r12
    call    check_block
    jmp     .exit

.return_stmt:
    mov     rax, [rbx + AST_A_OFF]      ; expr, 0 if absent
    cmp     r12, 0
    je      .return_expect_void
    cmp     rax, 0
    je      .return_missing_value
    mov     rdi, rax
    mov     rsi, r12
    call    check_expr
    mov     rdi, rax
    mov     rsi, r12
    call    types_equal
    cmp     rax, 0
    jne     .exit
    call    sema_report_begin
    mov     rsi, msg_return_type_mismatch
    mov     rdx, msg_return_type_mismatch_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.return_missing_value:
    call    sema_report_begin
    mov     rsi, msg_return_missing_value
    mov     rdx, msg_return_missing_value_len
    call    err_append_str
    mov     rdi, rbx
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.return_expect_void:
    cmp     rax, 0
    je      .exit
    call    sema_report_begin
    mov     rsi, msg_return_unexpected_value
    mov     rdx, msg_return_unexpected_value_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]      ; re-read -- the calls above
                                         ; clobber rax (caller-saved),
                                         ; same lesson as ast_dump.asm's
                                         ; emit_str-clobbers-rax fix
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish

.assign:
    mov     r13, [rbx + AST_A_OFF]      ; pairs ptr
    mov     r14, [rbx + AST_B_OFF]      ; pair_count
    xor     r15, r15
.assign_loop:
    cmp     r15, r14
    jae     .assign_dup_check
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_A_OFF]
    call    is_valid_lvalue
    cmp     rax, 0
    jne     .assign_lvalue_ok
    call    sema_report_begin
    mov     rsi, msg_invalid_lvalue
    mov     rdx, msg_invalid_lvalue_len
    call    err_append_str
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.assign_lvalue_ok:
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_A_OFF]
    call    check_const_reassignment
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, 0
    call    check_expr
    mov     r12, rax                    ; lvalue type (return_type not
                                         ; needed for the rest of .assign)
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_B_OFF]      ; rhs
    mov     rsi, r12
    call    check_expr
    mov     rdi, rax
    mov     rsi, r12
    call    types_equal
    cmp     rax, 0
    jne     .assign_pair_ok
    call    sema_report_begin
    mov     rsi, msg_assign_type_mismatch
    mov     rdx, msg_assign_type_mismatch_len
    call    err_append_str
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.assign_pair_ok:
    inc     r15
    jmp     .assign_loop
.assign_dup_check:
    xor     r12, r12
.dup_outer:
    cmp     r12, r14
    jae     .exit
    mov     r15, r12
    inc     r15
.dup_inner:
    cmp     r15, r14
    jae     .dup_outer_next
    mov     rax, [r13 + r12*8]
    mov     rdi, [rax + AST_A_OFF]
    mov     rax, [r13 + r15*8]
    mov     rsi, [rax + AST_A_OFF]
    call    lvalue_equal
    cmp     rax, 0
    je      .dup_inner_next
    call    sema_report_begin
    mov     rsi, msg_duplicate_assign_target
    mov     rdx, msg_duplicate_assign_target_len
    call    err_append_str
    mov     rax, [r13 + r15*8]
    mov     rdi, [rax + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.dup_inner_next:
    inc     r15
    jmp     .dup_inner
.dup_outer_next:
    inc     r12
    jmp     .dup_outer

.exit:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; stmt_always_returns: in rdi = stmt node ptr. out: rax = 1/0.
; AST_STMT_RETURN is trivially 1. AST_STMT_IF is 1 only if it has an else
; branch AND both branches always-return -- no else means the no-else
; path definitely falls through. AST_STMT_WHILE is 0 in general (no
; `break` in this language, but a loop body can still run zero times
; unless the condition is unconditionally true, which this analysis
; doesn't reason about for arbitrary expressions) -- except the one sound
; special case: a condition that is literally the `true` literal can only
; ever exit via `return` (or loop forever, which is an equally valid way
; to never fall past this point, same as e.g. Rust's `loop {}`),
; regardless of what the body does. Everything else (ASSIGN/EXPR) is 0.
; ===========================================================================
stmt_always_returns:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_STMT_RETURN
    je      .yes
    cmp     rax, AST_STMT_IF
    je      .if_stmt
    cmp     rax, AST_STMT_WHILE
    je      .while_stmt
    jmp     .no
.if_stmt:
    mov     rax, [rbx + AST_C_OFF]      ; else_block, 0 if absent
    cmp     rax, 0
    je      .no
    mov     rdi, [rbx + AST_B_OFF]      ; then_block
    mov     rsi, [rdi + AST_B_OFF]      ; its stmt_count
    mov     rdi, [rdi + AST_A_OFF]      ; its stmts ptr
    call    stmts_always_return
    cmp     rax, 0
    je      .no
    mov     rax, [rbx + AST_C_OFF]      ; else_block (re-derive -- the
                                         ; call above clobbered rax)
    mov     rsi, [rax + AST_B_OFF]
    mov     rdi, [rax + AST_A_OFF]
    call    stmts_always_return
    jmp     .done
.while_stmt:
    mov     rax, [rbx + AST_A_OFF]      ; cond
    mov     rcx, [rax + AST_KIND_OFF]
    cmp     rcx, AST_EX_BOOL
    jne     .no
    cmp     qword [rax + AST_A_OFF], 1
    jne     .no
.yes:
    mov     rax, 1
    jmp     .done
.no:
    xor     rax, rax
.done:
    pop     rbx
    ret

; ===========================================================================
; stmts_always_return: in rdi = stmts ptr (array of stmt node ptrs),
; rsi = count. out: rax = 1/0 -- true iff *any* statement in the list
; always-returns (an earlier always-returning statement makes everything
; after it unreachable regardless of its own shape; this phase adds no
; separate "unreachable code" diagnostic, it just doesn't let dead code's
; shape affect the verdict). Shared verbatim by AST_BLOCK (a=stmts,
; b=count) and AST_FUNC_BLOCK (c=stmts, d=stmt_count) -- same array-of-
; node-ptrs shape, callers just pass the right fields.
; ===========================================================================
stmts_always_return:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                    ; stmts ptr
    mov     r12, rsi                    ; count
    xor     r13, r13                    ; index
.loop:
    cmp     r13, r12
    jae     .no
    mov     rdi, [rbx + r13*8]
    call    stmt_always_returns
    cmp     rax, 0
    jne     .yes
    inc     r13
    jmp     .loop
.yes:
    mov     rax, 1
    jmp     .done
.no:
    xor     rax, rax
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; mk_base / mk_ptr_base: internal. in rdi = builtin TOK_KW_* tag. out rax
; = a freshly synthesized AST_TY_BASE{tag} / AST_TY_POINTER{BASE{tag}}
; node -- used only to build the fixed expected shapes for the extern
; syscall whitelist below.
; ===========================================================================
mk_base:
    mov     rsi, rdi
    mov     rdi, AST_TY_BASE
    push    rsi
    call    ast_alloc_node
    pop     rsi
    mov     [rax + AST_A_OFF], rsi
    mov     qword [rax + AST_B_OFF], 0
    mov     qword [rax + AST_C_OFF], 0
    ret

mk_ptr_base:
    call    mk_base
    mov     rcx, rax
    mov     rdi, AST_TY_POINTER
    push    rcx
    call    ast_alloc_node
    pop     rcx
    mov     [rax + AST_A_OFF], rcx
    ret

; ===========================================================================
; check_param_exact: in rdi = signature ptr, rsi = param index, rdx =
; expected type node. Reports "signature mismatch" (using the signature's
; own name) and never returns if the param's declared type isn't exactly
; the expected one.
; ===========================================================================
check_param_exact:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rdx
    mov     rax, [rbx + AST_C_OFF]      ; params ptr
    mov     rax, [rax + rsi*8]          ; AST_PARAM ptr
    mov     rax, [rax + AST_C_OFF]      ; declared type
    mov     rdi, rax
    mov     rsi, r12
    call    types_equal
    cmp     rax, 0
    jne     .ok
    call    sema_report_begin
    mov     rsi, msg_extern_signature_mismatch
    mov     rdx, msg_extern_signature_mismatch_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    err_append_span
    mov     rsi, msg_extern_signature_mismatch_2
    mov     rdx, msg_extern_signature_mismatch_2_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    jmp     sema_report_finish
.ok:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_return_exact: in rdi = AST_EXTERN_DECL ptr, rsi = expected return
; type node (0 = expect void). Same reporting shape as check_param_exact.
; ===========================================================================
check_return_exact:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_B_OFF]      ; actual return_type (0 = void)
    cmp     rsi, 0
    jne     .expect_nonvoid
    cmp     rax, 0
    je      .ok
    jmp     .mismatch
.expect_nonvoid:
    cmp     rax, 0
    je      .mismatch
    mov     rdi, rax
    call    types_equal
    cmp     rax, 0
    jne     .ok
.mismatch:
    call    sema_report_begin
    mov     rsi, msg_extern_signature_mismatch
    mov     rdx, msg_extern_signature_mismatch_len
    call    err_append_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, [rax + AST_B_OFF]
    call    err_append_span
    mov     rsi, msg_extern_signature_mismatch_2
    mov     rdx, msg_extern_signature_mismatch_2_len
    call    err_append_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rdi, [rax + AST_A_OFF]
    jmp     sema_report_finish
.ok:
    pop     rbx
    ret

; ===========================================================================
; check_extern_whitelist: in rdi = AST_EXTERN_DECL ptr. Validates the
; name is one of the fixed set of Stage 0-recognized syscalls and that
; the declared signature matches exactly (main spec section 2).
; ===========================================================================
check_extern_whitelist:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     rax, [rbx + AST_A_OFF]      ; signature ptr
    mov     r12, [rax + AST_A_OFF]      ; name_offset
    mov     r13, [rax + AST_B_OFF]      ; name_len

    cmp     r13, 8
    jne     .not_read
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, str_sys_read
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .is_read_write
.not_read:
    cmp     r13, 9
    jne     .not_write
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, str_sys_write
    mov     rdx, 9
    call    bytes_equal
    cmp     rax, 1
    je      .is_read_write
.not_write:
    cmp     r13, 8
    jne     .not_mmap
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, str_sys_mmap
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .is_mmap
.not_mmap:
    cmp     r13, 8
    jne     .not_exit
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, str_sys_exit
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .is_exit
.not_exit:
    call    sema_report_begin
    mov     rsi, msg_extern_not_whitelisted
    mov     rdx, msg_extern_not_whitelisted_len
    call    err_append_str
    mov     rdi, r12
    mov     rsi, r13
    call    err_append_span
    mov     rsi, msg_extern_not_whitelisted_2
    mov     rdx, msg_extern_not_whitelisted_2_len
    call    err_append_str
    mov     rdi, r12
    jmp     sema_report_finish

; sys_read / sys_write: (fd: int64, buf: *uint8, count: uint64) : int64
.is_read_write:
    mov     rax, [rbx + AST_A_OFF]
    mov     rcx, [rax + AST_D_OFF]
    cmp     rcx, 3
    jne     .sig_mismatch

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_param_exact

    mov     rdi, TOK_KW_UINT8
    call    mk_ptr_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 1
    call    check_param_exact

    mov     rdi, TOK_KW_UINT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 2
    call    check_param_exact

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rsi, rax
    mov     rdi, rbx
    call    check_return_exact
    jmp     .done

; sys_mmap: (addr: uint64, length: uint64, prot: int64, flags: int64,
; fd: int64, offset: int64) : *uint8
.is_mmap:
    mov     rax, [rbx + AST_A_OFF]
    mov     rcx, [rax + AST_D_OFF]
    cmp     rcx, 6
    jne     .sig_mismatch

    mov     rdi, TOK_KW_UINT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_param_exact

    mov     rdi, TOK_KW_UINT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 1
    call    check_param_exact

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 2
    call    check_param_exact

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 3
    call    check_param_exact

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 4
    call    check_param_exact

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 5
    call    check_param_exact

    mov     rdi, TOK_KW_UINT8
    call    mk_ptr_base
    mov     rsi, rax
    mov     rdi, rbx
    call    check_return_exact
    jmp     .done

; sys_exit: (code: int64) : void
.is_exit:
    mov     rax, [rbx + AST_A_OFF]
    mov     rcx, [rax + AST_D_OFF]
    cmp     rcx, 1
    jne     .sig_mismatch

    mov     rdi, TOK_KW_INT64
    call    mk_base
    mov     rdx, rax
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_param_exact

    xor     rsi, rsi
    mov     rdi, rbx
    call    check_return_exact
    jmp     .done

.sig_mismatch:
    call    sema_report_begin
    mov     rsi, msg_extern_signature_mismatch
    mov     rdx, msg_extern_signature_mismatch_len
    call    err_append_str
    mov     rdi, r12
    mov     rsi, r13
    call    err_append_span
    mov     rsi, msg_extern_signature_mismatch_2
    mov     rdx, msg_extern_signature_mismatch_2_len
    call    err_append_str
    mov     rdi, r12
    jmp     sema_report_finish

.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_function_body: internal. in rdi = AST_FUNCTION ptr. Builds the
; function's local table (params + decls, also resolving each local's
; declared type) and checks its body.
; ===========================================================================
check_function_body:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     rax, [rbx + AST_A_OFF]      ; signature ptr
    mov     rcx, [rbx + AST_C_OFF]      ; body (func_block)
    mov     rdi, rax
    mov     rsi, rcx
    call    build_local_table
    mov     r12, [rbx + AST_B_OFF]      ; return_type (0 = void)
    mov     rdi, [rbx + AST_C_OFF]
    mov     rsi, r12
    call    check_func_block

    cmp     r12, 0
    je      .void_ok                    ; void functions may fall off the
                                         ; end, nothing to check
    mov     rax, [rbx + AST_C_OFF]      ; func_block ptr
    mov     rdi, [rax + AST_C_OFF]      ; its stmts ptr
    mov     rsi, [rax + AST_D_OFF]      ; its stmt_count
    call    stmts_always_return
    cmp     rax, 0
    jne     .void_ok
    call    sema_report_begin
    mov     rsi, msg_missing_return_path
    mov     rdx, msg_missing_return_path_len
    call    err_append_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, [rax + AST_B_OFF]
    call    err_append_span
    mov     rsi, msg_missing_return_path_2
    mov     rdx, msg_missing_return_path_2_len
    call    err_append_str
    mov     rax, [rbx + AST_A_OFF]
    mov     rdi, [rax + AST_A_OFF]
    jmp     sema_report_finish
.void_ok:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; check_program: in rdi = AST_PROGRAM ptr. Top-level entry point, called
; once by checker_main.asm. Pass 1a (build_global_tables) + pass 1b
; (resolve_all_types), then pass 2: every function body checked, every
; extern validated against the whitelist. Structs need nothing further --
; resolve_all_types already validated their field types.
; ===========================================================================
check_program:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi

    call    build_global_tables
    mov     rdi, rbx
    call    resolve_all_types

    mov     r12, [rbx + AST_A_OFF]      ; decls ptr
    mov     r13, [rbx + AST_B_OFF]      ; decl_count
    xor     r14, r14
.loop:
    cmp     r14, r13
    jae     .done
    mov     rax, [r12 + r14*8]
    mov     rcx, [rax + AST_KIND_OFF]
    cmp     rcx, AST_FUNCTION
    je      .is_function
    cmp     rcx, AST_EXTERN_DECL
    je      .is_extern
    jmp     .next                        ; struct_decl: nothing further
.is_function:
    mov     rdi, rax
    call    check_function_body
    jmp     .next
.is_extern:
    mov     rdi, rax
    call    check_extern_whitelist
.next:
    inc     r14
    jmp     .loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
