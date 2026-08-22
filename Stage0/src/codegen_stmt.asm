; Postulate Stage 0 -- code generator: statement codegen.
; See docs/postulate_stage0_codegen_spec.md.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern gen_rvalue
extern gen_lvalue
extern gen_named_local_addr
extern emit_sized_store
extern emit_str
extern emit_nl
extern next_label_suffix
extern emit_label_def
extern emit_label_ref
extern check_supported_scalar_type

extern s_je_dotL
extern s_je_dotL_len
extern s_jmp_dotL
extern s_jmp_dotL_len
extern s_cmp_rax_0
extern s_cmp_rax_0_len
extern s_suf_else
extern s_suf_else_len
extern s_suf_end
extern s_suf_end_len
extern s_suf_start
extern s_suf_start_len
extern s_empty
extern s_empty_len

global gen_decl
global gen_stmt
global gen_block
global gen_func_block

section .data
s_push_rbx: db "    push    rbx"
s_push_rbx_len equ $ - s_push_rbx
s_push_rax: db "    push    rax"
s_push_rax_len equ $ - s_push_rax
s_pop_rax: db "    pop     rax"
s_pop_rax_len equ $ - s_pop_rax
s_pop_rbx: db "    pop     rbx"
s_pop_rbx_len equ $ - s_pop_rbx
s_jmp_epilogue: db "    jmp     .epilogue"
s_jmp_epilogue_len equ $ - s_jmp_epilogue

section .text

; ===========================================================================
; gen_decl: in rdi = AST_DECL_MUT/AST_DECL_CONST node ptr. Emits nothing if
; no initializer (matches "mut without init" leaving the slot's memory
; uninitialized). With an initializer: gen_rvalue first (value -> target
; rax), THEN the target address (gen_named_local_addr -> target rbx) --
; safe in this order specifically because address computation for a plain
; local never touches rax, so no push/pop staging is needed here (unlike
; AST_STMT_ASSIGN's general two-pass scheme, which must handle lvalues
; whose OWN address computation uses rax as scratch, ld. gen_stmt below).
; ===========================================================================
gen_decl:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     rdi, [rbx + AST_C_OFF]      ; declared type
    call    check_supported_scalar_type
    mov     rax, [rbx + AST_D_OFF]      ; init, 0 if absent
    cmp     rax, 0
    je      .done
    mov     rdi, rax
    call    gen_rvalue                  ; -> target rax = value
    mov     rdi, [rbx + AST_A_OFF]      ; name_offset
    mov     rsi, [rbx + AST_B_OFF]      ; name_len
    call    gen_named_local_addr        ; -> target rbx = address; rax(ours) = type
    mov     r12, rax
    mov     rdi, r12
    call    emit_sized_store
.done:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_stmt: in rdi = stmt node ptr. Emits the statement's code. No
; return-type parameter -- RETURN's own codegen never needs one: with
; scalar-only returns (rax, ld. Calling convention), no sizing/conversion
; is needed, and the value's type was already checker-validated before
; codegen ever runs.
; ===========================================================================
gen_stmt:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_STMT_EXPR
    je      .expr_stmt
    cmp     rax, AST_STMT_IF
    je      .if_stmt
    cmp     rax, AST_STMT_WHILE
    je      .while_stmt
    cmp     rax, AST_STMT_RETURN
    je      .return_stmt
    cmp     rax, AST_STMT_ASSIGN
    je      .assign
    jmp     .exit                        ; unreachable per grammar

.expr_stmt:
    mov     rdi, [rbx + AST_A_OFF]
    call    gen_rvalue
    jmp     .exit

.if_stmt:
    call    next_label_suffix
    mov     r12, rax                    ; unique suffix
    mov     rdi, [rbx + AST_A_OFF]      ; cond
    call    gen_rvalue
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    call    emit_str
    call    emit_nl
    mov     rax, [rbx + AST_C_OFF]      ; else_block, 0 if absent
    cmp     rax, 0
    je      .if_no_else
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_else
    mov     rdx, s_suf_else_len
    call    emit_label_ref
    call    emit_nl
    mov     rdi, [rbx + AST_B_OFF]      ; then_block
    call    gen_block
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_ref
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_else
    mov     rdx, s_suf_else_len
    call    emit_label_def
    mov     rdi, [rbx + AST_C_OFF]      ; else_block
    call    gen_block
    jmp     .if_end
.if_no_else:
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_ref
    call    emit_nl
    mov     rdi, [rbx + AST_B_OFF]      ; then_block
    call    gen_block
.if_end:
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    jmp     .exit

.while_stmt:
    call    next_label_suffix
    mov     r12, rax
    mov     rax, r12
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    call    emit_label_def
    mov     rdi, [rbx + AST_A_OFF]      ; cond
    call    gen_rvalue
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_ref
    call    emit_nl
    mov     rdi, [rbx + AST_B_OFF]      ; body
    call    gen_block
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    call    emit_label_ref
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    jmp     .exit

.return_stmt:
    mov     rax, [rbx + AST_A_OFF]      ; expr, 0 if absent
    cmp     rax, 0
    je      .return_jmp
    mov     rdi, rax
    call    gen_rvalue                  ; -> target rax = return value
.return_jmp:
    mov     rsi, s_jmp_epilogue
    mov     rdx, s_jmp_epilogue_len
    call    emit_str
    call    emit_nl
    jmp     .exit

; --- ASSIGN: Dijkstra/Hoare simultaneous-assignment. Two passes: pass 1
; computes and pushes (address, value) for every pair left to right
; (against pre-statement state); pass 2 pops and stores in reverse. Each
; pair's target TYPE (needed for emit_sized_store's sizing, only known
; after pass 1's gen_lvalue call) is stashed in a small scratch array on
; OUR OWN (the Stage0 compiler's) native stack, indexed by pair index --
; entirely separate from the "push"/"pop" TEXT this routine emits into the
; output buffer for the *target* program's stack. rbx is repurposed here
; as that scratch array's base pointer once the pairs ptr/count are safely
; off it into r12/r13 -- same "stable base in rbx" idiom sema_expr.asm's
; struct_lit scratch region uses (there via r14, since rbx there is
; already the checker's own node-pointer register; here rbx is free for
; this exact purpose since gen_stmt's own node ptr isn't needed again
; once the pairs ptr/count are captured).
.assign:
    mov     r12, [rbx + AST_A_OFF]      ; pairs ptr
    mov     r13, [rbx + AST_B_OFF]      ; pair_count
    sub     rsp, MAX_LIST_ARITY * 8     ; scratch: one qword per pair,
                                         ; each pair's lhs type ptr
    mov     rbx, rsp
    xor     r14, r14
.assign_pass1:
    cmp     r14, r13
    jae     .assign_pass2_init
    mov     rax, [r12 + r14*8]          ; pair ptr
    mov     rdi, [rax + AST_A_OFF]      ; lhs
    call    gen_lvalue                  ; -> target rbx = address; rax(ours) = type
    mov     [rbx + r14*8], rax          ; stash type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl
    mov     rax, [r12 + r14*8]          ; re-derive pair ptr (emit_str
                                         ; clobbers rax)
    mov     rdi, [rax + AST_B_OFF]      ; rhs
    call    gen_rvalue                  ; -> target rax = value
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    call    emit_str
    call    emit_nl
    inc     r14
    jmp     .assign_pass1
.assign_pass2_init:
    mov     r14, r13
.assign_pass2:
    cmp     r14, 0
    je      .assign_done
    dec     r14
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    call    emit_str
    call    emit_nl                     ; target rax = value
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl                     ; target rbx = address
    mov     rdi, [rbx + r14*8]          ; stashed lhs type
    call    emit_sized_store
    jmp     .assign_pass2
.assign_done:
    add     rsp, MAX_LIST_ARITY * 8
    jmp     .exit

.exit:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_block: in rdi = AST_BLOCK ptr. Generates every statement in it.
; ===========================================================================
gen_block:
    push    rbx
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r13, [rbx + AST_A_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_B_OFF]      ; stmt_count
    xor     rcx, rcx
.loop:
    cmp     rcx, r14
    jae     .done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    call    gen_stmt
    pop     rcx
    inc     rcx
    jmp     .loop
.done:
    pop     r14
    pop     r13
    pop     rbx
    ret

; ===========================================================================
; gen_func_block: in rdi = AST_FUNC_BLOCK ptr. Generates every decl's
; init, then every statement.
; ===========================================================================
gen_func_block:
    push    rbx
    push    r13
    push    r14
    mov     rbx, rdi

    mov     r13, [rbx + AST_A_OFF]      ; decls ptr
    mov     r14, [rbx + AST_B_OFF]      ; decl_count
    xor     rcx, rcx
.decl_loop:
    cmp     rcx, r14
    jae     .decls_done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    call    gen_decl
    pop     rcx
    inc     rcx
    jmp     .decl_loop
.decls_done:
    mov     r13, [rbx + AST_C_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_D_OFF]      ; stmt_count
    xor     rcx, rcx
.stmt_loop:
    cmp     rcx, r14
    jae     .done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    call    gen_stmt
    pop     rcx
    inc     rcx
    jmp     .stmt_loop
.done:
    pop     r14
    pop     r13
    pop     rbx
    ret
