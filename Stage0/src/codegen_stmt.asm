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
extern emit_sized_load
extern emit_str
extern emit_nl
extern next_label_suffix
extern emit_label_def
extern emit_label_ref
extern is_scalar_loadable_type
extern type_size
extern types_equal
extern codegen_fail
extern gen_init_push
extern gen_init_pop_store
extern emit_rep_movsb_copy
extern gen_composite_broadcast

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
s_mov_rdi_rbx: db "    mov     rdi, rbx"
s_mov_rdi_rbx_len equ $ - s_mov_rdi_rbx
s_mov_rsi_rbx: db "    mov     rsi, rbx"
s_mov_rsi_rbx_len equ $ - s_mov_rsi_rbx
s_pop_rsi: db "    pop     rsi"
s_pop_rsi_len equ $ - s_pop_rsi
s_pop_rdi: db "    pop     rdi"
s_pop_rdi_len equ $ - s_pop_rdi

msg_composite_broadcast_unsupported: db "broadcasting a struct/array value across array elements is not supported by this codegen phase yet"
msg_composite_broadcast_unsupported_len equ $ - msg_composite_broadcast_unsupported

section .text

; ===========================================================================
; gen_decl: in rdi = AST_DECL_MUT/AST_DECL_CONST node ptr. Emits nothing if
; no initializer (matches "mut without init" leaving the slot's memory
; uninitialized). With an initializer, dispatches on the declared type:
;
; - scalar/pointer: gen_rvalue first (value -> target rax), THEN the
;   target address (gen_named_local_addr -> target rbx) -- safe in this
;   order specifically because address computation for a plain local
;   never touches rax, so no push/pop staging is needed (unlike
;   AST_STMT_ASSIGN's general two-pass scheme, ld. gen_stmt below).
; - struct/array, init is a STRUCT_LIT/ARRAY_LIT: gen_init_push (pass 1)
;   then gen_named_local_addr + gen_init_pop_store (pass 2) -- no
;   push/pop of the address needed here either (single-write, no
;   simultaneity concern), unlike the multi-pair ASSIGN case.
; - struct/array, init is a plain lvalue of the exact same composite
;   type (`p2 := p1;`-shaped): gen_composite_copy via emit_rep_movsb_copy.
; - struct/array, init is anything else (guaranteed scalar/pointer by
;   construction once composite-returning functions are rejected
;   elsewhere): array broadcast-init (Part A1's checker rule made this
;   reachable) -- gen_composite_broadcast. A composite-typed broadcast
;   source (matches the array's element type, itself composite) is a
;   deliberately deferred, narrow scope cut -- codegen_fail with a clear
;   message rather than mishandle it.
; ===========================================================================
gen_decl:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     rax, [rbx + AST_D_OFF]      ; init, 0 if absent
    cmp     rax, 0
    je      .done
    mov     r12, [rbx + AST_C_OFF]      ; declared type
    mov     r13, rax                    ; init node

    mov     rdi, r12
    call    is_scalar_loadable_type
    cmp     rax, 0
    je      .composite

    ; --- scalar/pointer path ---
    mov     rdi, r13
    call    gen_rvalue                  ; -> target rax = value
    mov     rdi, [rbx + AST_A_OFF]      ; name_offset
    mov     rsi, [rbx + AST_B_OFF]      ; name_len
    call    gen_named_local_addr        ; -> target rbx = address; rax(ours) = type
    mov     rdi, rax
    call    emit_sized_store
    jmp     .done

.composite:
    mov     rax, [r13 + AST_KIND_OFF]
    cmp     rax, AST_EX_STRUCT_LIT
    je      .literal
    cmp     rax, AST_EX_ARRAY_LIT
    je      .literal
    cmp     rax, AST_EX_IDENT
    je      .maybe_copy
    cmp     rax, AST_EX_INDEX
    je      .maybe_copy
    cmp     rax, AST_EX_FIELD
    je      .maybe_copy
    cmp     rax, AST_EX_UNARY
    jne     .broadcast_scalar
    mov     rcx, [r13 + AST_A_OFF]      ; op
    cmp     rcx, TOK_STAR
    jne     .broadcast_scalar
    ; UNARY(*): falls through to .maybe_copy -- deref of a
    ; pointer-to-composite is lvalue-shaped exactly like IDENT/INDEX/FIELD

.maybe_copy:
    mov     rdi, r13
    call    gen_lvalue                  ; -> target rbx = src addr;
                                         ; rax(ours) = resolved type
    push    rax                         ; resolved type -- protect it
                                         ; ourselves across types_equal via
                                         ; an explicit push/pop; we are the
                                         ; ones who need it to survive, so
                                         ; we don't delegate that to any
                                         ; callee-saved-register convention
    mov     rdi, rax
    mov     rsi, r12
    call    types_equal
    pop     rcx                         ; resolved type back
    cmp     rax, 0
    je      .broadcast_composite_check

    ; --- COPY case: rbx already = src address ---
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    gen_named_local_addr        ; -> target rbx = dest addr
    mov     rsi, s_mov_rdi_rbx
    mov     rdx, s_mov_rdi_rbx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_mov_rsi_rbx
    mov     rdx, s_mov_rsi_rbx_len
    call    emit_str
    call    emit_nl
    mov     rdi, r12
    call    type_size
    mov     rdi, rax
    call    emit_rep_movsb_copy
    jmp     .done

.broadcast_composite_check:
    push    rcx                         ; resolved type -- protect across
                                         ; is_scalar_loadable_type, same
                                         ; rule: we own the obligation to
                                         ; keep it alive, not the callee
    mov     rdi, rcx
    call    is_scalar_loadable_type
    pop     rcx
    cmp     rax, 0
    je      .broadcast_unsupported
    mov     rdi, rcx
    call    emit_sized_load             ; -> target rax = value
    jmp     .broadcast_common

.broadcast_scalar:
    mov     rdi, r13
    call    gen_rvalue                  ; -> target rax = value
    jmp     .broadcast_common

.broadcast_common:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    gen_named_local_addr        ; -> target rbx = array base addr
                                         ; (never touches target rax)
    mov     rdi, [r12 + AST_A_OFF]      ; array's element type
    mov     rsi, [r12 + AST_B_OFF]      ; array's element count
    call    gen_composite_broadcast
    jmp     .done

.broadcast_unsupported:
    mov     rsi, msg_composite_broadcast_unsupported
    mov     rdx, msg_composite_broadcast_unsupported_len
    call    codegen_fail

.literal:
    mov     rdi, r13
    call    gen_init_push
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    gen_named_local_addr        ; -> target rbx = addr
    mov     rdi, r13                    ; literal node
    mov     rsi, r12                    ; expected type (declared type)
    xor     rdx, rdx                    ; accumulated offset = 0
    call    gen_init_pop_store
.done:
    pop     r13
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
    push    r15
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

; --- ASSIGN: Dijkstra/Hoare simultaneous-assignment. Two passes, per
; pair, in one of four shapes (classified structurally, no emission
; needed to decide which): SCALAR/pointer (unchanged from Phase 1),
; composite LITERAL (ld. codegen_composite.asm's gen_init_push/
; gen_init_pop_store), composite COPY (`p2 := p1;`-shaped), and array
; BROADCAST (Part A1's checker rule). Each pair's own (shape, lhs type)
; is stashed in a 2-qword-per-pair scratch array on OUR OWN (the Stage0
; compiler's) native stack -- entirely separate from the "push"/"pop"
; TEXT this routine emits into the output buffer for the *target*
; program's stack. rbx is repurposed as that scratch array's base
; pointer once the pairs ptr/count are safely off it into r12/r13 (same
; "stable base in rbx" idiom sema_expr.asm's struct_lit scratch region
; uses) -- safe to keep alive across every nested gen_lvalue/gen_rvalue/
; etc. call this whole routine makes, since all of them explicitly
; preserve rbx/r12/r13/r14 for their caller; r15 is likewise free and
; used here as an extra pair-local temporary (lhs type).
;
; Push-pattern per shape, pass 1 (address-vs-value/leaves ordering
; matters -- ld. codegen spec for why): SCALAR/BROADCAST = address then
; value; LITERAL = leaves (gen_init_push) then address, address pushed
; LAST; COPY = dest address then src address. Pass 2 (this pair's turn,
; overall pairs processed in reverse) undoes exactly that shape's
; ordering.
.assign:
    mov     r12, [rbx + AST_A_OFF]      ; pairs ptr
    mov     r13, [rbx + AST_B_OFF]      ; pair_count
    sub     rsp, MAX_LIST_ARITY * 16    ; scratch: 2 qwords per pair --
                                         ; shape tag, lhs type
    mov     rbx, rsp
    xor     r14, r14
.assign_pass1:
    cmp     r14, r13
    jae     .assign_pass2_init
    mov     rax, [r12 + r14*8]          ; pair ptr
    mov     rcx, [rax + AST_B_OFF]      ; rhs node
    mov     rdx, [rcx + AST_KIND_OFF]
    cmp     rdx, AST_EX_STRUCT_LIT
    je      .p1_literal
    cmp     rdx, AST_EX_ARRAY_LIT
    je      .p1_literal
    jmp     .p1_not_literal

.p1_literal:
    mov     rdi, rcx                    ; rhs literal node
    call    gen_init_push               ; leaves pushed, forward order
    mov     rax, [r12 + r14*8]          ; pair ptr, re-derive
    mov     rdi, [rax + AST_A_OFF]      ; lhs
    call    gen_lvalue                  ; -> rax(ours) = lhs type; emits
                                         ; the address computation, AFTER
                                         ; the leaves (deliberately)
    mov     r15, rax                    ; lhs type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl                     ; address pushed LAST
    mov     r9, r14
    shl     r9, 4
    add     r9, rbx                     ; r9 = this pair's scratch slot
                                         ; (r14*16 isn't a valid SIB scale)
    mov     qword [r9], 1               ; shape = LITERAL
    mov     [r9 + 8], r15
    jmp     .p1_next

.p1_not_literal:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_A_OFF]      ; lhs
    call    gen_lvalue                  ; -> rax(ours) = lhs type; emits
                                         ; address computation
    mov     r15, rax                    ; lhs type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl                     ; address pushed FIRST
    mov     rdi, r15
    call    is_scalar_loadable_type
    cmp     rax, 0
    je      .p1_composite
    ; --- SCALAR ---
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_B_OFF]      ; rhs
    call    gen_rvalue                  ; -> target rax = value
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    call    emit_str
    call    emit_nl
    mov     r9, r14
    shl     r9, 4
    add     r9, rbx
    mov     qword [r9], 0               ; shape = SCALAR
    mov     [r9 + 8], r15
    jmp     .p1_next

.p1_composite:
    mov     rax, [r12 + r14*8]
    mov     rax, [rax + AST_B_OFF]      ; rhs node
    mov     rcx, [rax + AST_KIND_OFF]
    cmp     rcx, AST_EX_IDENT
    je      .p1_maybe_copy
    cmp     rcx, AST_EX_INDEX
    je      .p1_maybe_copy
    cmp     rcx, AST_EX_FIELD
    je      .p1_maybe_copy
    cmp     rcx, AST_EX_UNARY
    jne     .p1_broadcast_scalar
    mov     rcx, [rax + AST_A_OFF]      ; op
    cmp     rcx, TOK_STAR
    jne     .p1_broadcast_scalar
    ; UNARY(*): falls through to .p1_maybe_copy

.p1_maybe_copy:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_B_OFF]      ; rhs
    call    gen_lvalue                  ; -> rax(ours) = rhs type; emits
                                         ; src address computation
    push    rax                         ; protect rhs type across types_equal
    mov     rdi, rax
    mov     rsi, r15                    ; lhs type
    call    types_equal
    pop     rcx                         ; rhs type back
    cmp     rax, 0
    je      .p1_broadcast_composite_check
    ; --- COPY ---
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl                     ; src addr pushed (on top of the
                                         ; dest addr already pushed above)
    mov     r9, r14
    shl     r9, 4
    add     r9, rbx
    mov     qword [r9], 2               ; shape = COPY
    mov     [r9 + 8], r15
    jmp     .p1_next

.p1_broadcast_composite_check:
    push    rcx                         ; rhs type -- protect across
                                         ; is_scalar_loadable_type below;
                                         ; rcx is never trustworthy across
                                         ; a call in this codebase (ld.
                                         ; type_size's own scratch use)
    mov     rdi, rcx
    call    is_scalar_loadable_type
    pop     rcx
    cmp     rax, 0
    je      .p1_broadcast_unsupported
    mov     rdi, rcx
    call    emit_sized_load             ; loads from (target) src addr
                                         ; into target rax
    jmp     .p1_broadcast_push
.p1_broadcast_scalar:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_B_OFF]
    call    gen_rvalue                  ; -> target rax = value
.p1_broadcast_push:
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    call    emit_str
    call    emit_nl
    mov     r9, r14
    shl     r9, 4
    add     r9, rbx
    mov     qword [r9], 3               ; shape = BROADCAST
    mov     [r9 + 8], r15
    jmp     .p1_next
.p1_broadcast_unsupported:
    mov     rsi, msg_composite_broadcast_unsupported
    mov     rdx, msg_composite_broadcast_unsupported_len
    call    codegen_fail

.p1_next:
    inc     r14
    jmp     .assign_pass1

.assign_pass2_init:
    mov     r14, r13
.assign_pass2:
    cmp     r14, 0
    je      .assign_done
    dec     r14
    mov     r9, r14
    shl     r9, 4
    add     r9, rbx
    mov     rax, [r9]                   ; shape tag
    mov     r15, [r9 + 8]               ; lhs type
    cmp     rax, 0
    je      .p2_scalar
    cmp     rax, 1
    je      .p2_literal
    cmp     rax, 2
    je      .p2_copy
    ; shape == 3 (BROADCAST)
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    call    emit_str
    call    emit_nl                     ; target rax = value
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl                     ; target rbx = address
    mov     rdi, [r15 + AST_A_OFF]      ; element type
    mov     rsi, [r15 + AST_B_OFF]      ; element count
    call    gen_composite_broadcast
    jmp     .assign_pass2

.p2_scalar:
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    call    emit_str
    call    emit_nl                     ; target rax = value
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl                     ; target rbx = address
    mov     rdi, r15
    call    emit_sized_store
    jmp     .assign_pass2

.p2_literal:
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl                     ; target rbx = address (pushed
                                         ; last in pass 1 for this shape)
    mov     rax, [r12 + r14*8]          ; pair ptr, re-derive
    mov     rdi, [rax + AST_B_OFF]      ; rhs literal node
    mov     rsi, r15                    ; expected type = lhs type
    xor     rdx, rdx                    ; accumulated offset = 0
    call    gen_init_pop_store
    jmp     .assign_pass2

.p2_copy:
    mov     rsi, s_pop_rsi
    mov     rdx, s_pop_rsi_len
    call    emit_str
    call    emit_nl                     ; target rsi = src (pushed last)
    mov     rsi, s_pop_rdi
    mov     rdx, s_pop_rdi_len
    call    emit_str
    call    emit_nl                     ; target rdi = dest
    mov     rdi, r15
    call    type_size
    mov     rdi, rax
    call    emit_rep_movsb_copy
    jmp     .assign_pass2

.assign_done:
    add     rsp, MAX_LIST_ARITY * 16
    jmp     .exit

.exit:
    pop     r15
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
