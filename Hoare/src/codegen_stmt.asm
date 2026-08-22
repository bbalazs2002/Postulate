; Postulate Stage 0 -- code generator: statement codegen.
; See docs/postulate_stage0_codegen_spec.md.
;
; Register-safety convention (applies to every routine in this file): no
; callee, including the trivial ones (emit_str/emit_nl), is ever trusted
; to leave any register untouched across a call. Whenever a value must
; survive a call, the function that needs it pushes it immediately
; before that one call and pops it immediately after -- never spanning
; more than one call per push/pop pair. Note also that "rbx"/etc named
; in comments describing emitted text (e.g. "target rbx = address")
; refer to the EMITTED PROGRAM's runtime register, not this compiler's
; own rbx hardware register used for bookkeeping -- the two are entirely
; unrelated (emitting the text "push rbx" is just string manipulation,
; it never touches our own rbx). Consequently no routine here has a
; prologue/epilogue save of its caller's rbx/r12-r15 either: since every
; caller now protects its own values around each call it makes, a
; callee no longer needs to preserve its caller's incoming register
; contents on its own initiative.

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
extern emit_dec
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
extern cur_func_return_type
extern cur_func_out_ptr_offset

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
s_add_rsp_: db "    add     rsp, "
s_add_rsp__len equ $ - s_add_rsp_
s_mov_rdi_rbp_minus: db "    mov     rdi, [rbp - "
s_mov_rdi_rbp_minus_len equ $ - s_mov_rdi_rbp_minus
s_mov_rbx_rbp_minus: db "    mov     rbx, [rbp - "
s_mov_rbx_rbp_minus_len equ $ - s_mov_rbx_rbp_minus
s_close_bracket_nl: db "]", 10
s_close_bracket_nl_len equ $ - s_close_bracket_nl

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
;   AST_STMT_ASSIGN's general two-pass scheme, see gen_stmt below).
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
    mov     rbx, rdi
    mov     rax, [rbx + AST_D_OFF]      ; init, 0 if absent
    cmp     rax, 0
    je      .done
    mov     r12, [rbx + AST_C_OFF]      ; declared type
    mov     r13, rax                    ; init node

    mov     rdi, r12
    push    rbx
    push    r12
    push    r13
    call    is_scalar_loadable_type
    pop     r13
    pop     r12
    pop     rbx
    cmp     rax, 0
    je      .composite

    ; --- scalar/pointer path ---
    mov     rdi, r13
    push    rbx
    call    gen_rvalue                  ; -> target rax = value
    pop     rbx
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
    cmp     rax, AST_EX_CALL
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
    push    rbx
    push    r12
    call    gen_lvalue                  ; -> target rbx = src addr;
                                         ; rax(ours) = resolved type;
                                         ; r8(ours) = cleanup size (see
                                         ; gen_lvalue's own header)
    pop     r12
    pop     rbx
    push    rax                         ; resolved type -- protect it
                                         ; ourselves across types_equal via
                                         ; an explicit push/pop; we are the
                                         ; ones who need it to survive, so
                                         ; we don't delegate that to any
                                         ; callee-saved-register convention
    push    r8                          ; cleanup -- same rule
    mov     rdi, rax
    mov     rsi, r12
    push    rbx
    push    r12
    call    types_equal
    pop     r12
    pop     rbx
    pop     r8                          ; cleanup back
    pop     rcx                         ; resolved type back
    cmp     rax, 0
    je      .broadcast_composite_check

    ; --- COPY case ---
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    push    rbx
    push    r12
    push    r8
    call    emit_str
    pop     r8
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r8
    call    emit_nl
    pop     r8
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    push    r12
    push    r8
    call    gen_named_local_addr        ; -> target rbx = dest addr; our
                                         ; own rbx (decl node) is not
                                         ; needed again after this call
    pop     r8
    pop     r12
    mov     rsi, s_mov_rdi_rbx
    mov     rdx, s_mov_rdi_rbx_len
    push    r12
    push    r8
    call    emit_str
    pop     r8
    pop     r12
    push    r12
    push    r8
    call    emit_nl
    pop     r8
    pop     r12
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    push    r12
    push    r8
    call    emit_str
    pop     r8
    pop     r12
    push    r12
    push    r8
    call    emit_nl
    pop     r8
    pop     r12
    mov     rsi, s_mov_rsi_rbx
    mov     rdx, s_mov_rsi_rbx_len
    push    r12
    push    r8
    call    emit_str
    pop     r8
    pop     r12
    push    r12
    push    r8
    call    emit_nl
    pop     r8
    pop     r12
    mov     rdi, r12
    push    r8
    call    type_size
    pop     r8
    mov     rdi, rax
    push    r8
    call    emit_rep_movsb_copy
    pop     r8
    cmp     r8, 0
    je      .done
    mov     rsi, s_add_rsp_             ; free the temp the source came
    mov     rdx, s_add_rsp__len         ; from, now that we're done
    push    r8                          ; reading it (see gen_lvalue
    call    emit_str                    ; header -- no leak)
    pop     r8
    mov     rax, r8
    call    emit_dec
    call    emit_nl
    jmp     .done

.broadcast_composite_check:
    push    rbx
    push    r12
    push    rcx                         ; resolved type -- protect across
                                         ; is_scalar_loadable_type, same
                                         ; rule: we own the obligation to
                                         ; keep it alive, not the callee
    mov     rdi, rcx
    call    is_scalar_loadable_type
    pop     rcx
    pop     r12
    pop     rbx
    cmp     rax, 0
    je      .broadcast_unsupported
    push    rbx
    push    r12
    mov     rdi, rcx
    call    emit_sized_load             ; -> target rax = value
    pop     r12
    pop     rbx
    jmp     .broadcast_common

.broadcast_scalar:
    mov     rdi, r13
    push    rbx
    push    r12
    call    gen_rvalue                  ; -> target rax = value
    pop     r12
    pop     rbx
    jmp     .broadcast_common

.broadcast_common:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    push    r12
    call    gen_named_local_addr        ; -> target rbx = array base addr
                                         ; (never touches target rax); our
                                         ; own rbx (decl node) is not
                                         ; needed again after this call
    pop     r12
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
    push    rbx
    push    r12
    push    r13
    call    gen_init_push
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    push    r12
    push    r13
    call    gen_named_local_addr        ; -> target rbx = addr; our own
                                         ; rbx (decl node) is not needed
                                         ; again after this call
    pop     r13
    pop     r12
    mov     rdi, r13                    ; literal node
    mov     rsi, r12                    ; expected type (declared type)
    xor     rdx, rdx                    ; accumulated offset = 0
    call    gen_init_pop_store
.done:
    ret

; ===========================================================================
; gen_stmt: in rdi = stmt node ptr. Emits the statement's code. No
; return-type parameter -- RETURN's own codegen never needs one: with
; scalar-only returns (rax, see Calling convention), no sizing/conversion
; is needed, and the value's type was already checker-validated before
; codegen ever runs.
; ===========================================================================
gen_stmt:
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
    push    rbx
    call    next_label_suffix
    pop     rbx
    mov     r12, rax                    ; unique suffix
    mov     rdi, [rbx + AST_A_OFF]      ; cond
    push    rbx
    push    r12
    call    gen_rvalue
    pop     r12
    pop     rbx
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rax, [rbx + AST_C_OFF]      ; else_block, 0 if absent
    cmp     rax, 0
    je      .if_no_else
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    mov     rax, r12
    mov     rsi, s_suf_else
    mov     rdx, s_suf_else_len
    push    rbx
    push    r12
    call    emit_label_ref
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_B_OFF]      ; then_block
    push    rbx
    push    r12
    call    gen_block
    pop     r12
    pop     rbx
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    push    rbx
    push    r12
    call    emit_label_ref
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rax, r12
    mov     rsi, s_suf_else
    mov     rdx, s_suf_else_len
    push    rbx
    push    r12
    call    emit_label_def
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_C_OFF]      ; else_block
    push    r12
    call    gen_block
    pop     r12
    jmp     .if_end
.if_no_else:
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    push    rbx
    push    r12
    call    emit_label_ref
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_B_OFF]      ; then_block
    push    r12
    call    gen_block
    pop     r12
.if_end:
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    jmp     .exit

.while_stmt:
    push    rbx
    call    next_label_suffix
    pop     rbx
    mov     r12, rax
    mov     rax, r12
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    push    rbx
    push    r12
    call    emit_label_def
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_A_OFF]      ; cond
    push    rbx
    push    r12
    call    gen_rvalue
    pop     r12
    pop     rbx
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    push    rbx
    push    r12
    call    emit_str
    pop     r12
    pop     rbx
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    push    rbx
    push    r12
    call    emit_label_ref
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    call    emit_nl
    pop     r12
    pop     rbx
    mov     rdi, [rbx + AST_B_OFF]      ; body
    push    r12
    call    gen_block
    pop     r12
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    push    r12
    call    emit_str
    pop     r12
    mov     rax, r12
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    push    r12
    call    emit_label_ref
    pop     r12
    push    r12
    call    emit_nl
    pop     r12
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    jmp     .exit

.return_stmt:
    mov     rax, [rbx + AST_A_OFF]      ; expr, 0 if absent
    cmp     rax, 0
    je      .return_jmp
    mov     r12, rax                    ; expr node -- ours, protected
                                         ; throughout
    mov     r13, [cur_func_return_type] ; see codegen_program.asm's
                                         ; gen_function header -- set
                                         ; once, before this function's
                                         ; body is ever generated
    cmp     r13, 0
    je      .return_scalar              ; void with a value is
                                         ; unreachable (checker-
                                         ; rejected); falls through to
                                         ; the scalar path defensively
                                         ; rather than dereference a
                                         ; null return type below
    mov     rdi, r13
    push    r12
    push    r13
    call    is_scalar_loadable_type
    pop     r13
    pop     r12
    cmp     rax, 0
    jne     .return_scalar

    ; --- composite return: write straight into the caller-provided
    ; destination (its address was saved into this frame's hidden slot
    ; right after the prologue, see gen_function) ---
    mov     rax, [r12 + AST_KIND_OFF]
    cmp     rax, AST_EX_STRUCT_LIT
    je      .return_literal
    cmp     rax, AST_EX_ARRAY_LIT
    je      .return_literal

    ; lvalue-shaped source: gen_lvalue's own cleanup output (r8), if
    ; any, is deliberately left unhandled here -- we're about to jmp
    ; .epilogue, whose "mov rsp, rbp" tears down this whole frame
    ; (reservation included) regardless, see gen_lvalue's own header
    mov     rdi, r12
    push    r12
    push    r13
    call    gen_lvalue                  ; -> target rbx = src address
    pop     r13
    pop     r12
    mov     rsi, s_mov_rsi_rbx
    mov     rdx, s_mov_rsi_rbx_len
    push    r13
    call    emit_str
    pop     r13
    push    r13
    call    emit_nl                     ; target rsi = src
    pop     r13
    mov     rsi, s_mov_rdi_rbp_minus
    mov     rdx, s_mov_rdi_rbp_minus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, [cur_func_out_ptr_offset]
    push    r13
    call    emit_dec
    pop     r13
    mov     rsi, s_close_bracket_nl
    mov     rdx, s_close_bracket_nl_len
    push    r13
    call    emit_str                    ; target rdi = the SAVED output
    pop     r13                         ; pointer VALUE (dest)
    mov     rdi, r13
    call    type_size
    mov     rdi, rax
    call    emit_rep_movsb_copy
    jmp     .return_jmp

.return_literal:
    mov     rdi, r12
    push    r12
    push    r13
    call    gen_init_push               ; leaves pushed, forward order
    pop     r13
    pop     r12
    mov     rsi, s_mov_rbx_rbp_minus
    mov     rdx, s_mov_rbx_rbp_minus_len
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    mov     rax, [cur_func_out_ptr_offset]
    push    r12
    push    r13
    call    emit_dec
    pop     r13
    pop     r12
    mov     rsi, s_close_bracket_nl
    mov     rdx, s_close_bracket_nl_len
    push    r12
    push    r13
    call    emit_str                    ; target rbx = the SAVED output
    pop     r13                         ; pointer VALUE, computed AFTER
    pop     r12                         ; the leaves (deliberately, see
                                         ; gen_init_push's own header)
    mov     rdi, r12                    ; literal node
    mov     rsi, r13                    ; expected type = declared
                                         ; return type
    xor     rdx, rdx                    ; accumulated offset = 0
    call    gen_init_pop_store
    jmp     .return_jmp

.return_scalar:
    mov     rdi, r12
    call    gen_rvalue                  ; -> target rax = return value --
                                         ; nothing of ours is needed again
                                         ; after this, so no protection
.return_jmp:
    mov     rsi, s_jmp_epilogue
    mov     rdx, s_jmp_epilogue_len
    call    emit_str
    call    emit_nl
    jmp     .exit

; --- ASSIGN: Dijkstra/Hoare simultaneous-assignment. Two passes, per
; pair, in one of four shapes (classified structurally, no emission
; needed to decide which): SCALAR/pointer (unchanged from Phase 1),
; composite LITERAL (see codegen_composite.asm's gen_init_push/
; gen_init_pop_store), composite COPY (`p2 := p1;`-shaped), and array
; BROADCAST (Part A1's checker rule). Each pair's own (shape, lhs type)
; is stashed in a 2-qword-per-pair scratch array on OUR OWN (this
; compiler's, Hoare's) native stack -- entirely separate from the "push"/"pop"
; TEXT this routine emits into the output buffer for the *target*
; program's stack. rbx is repurposed as that scratch array's base
; pointer once the pairs ptr/count are safely off it into r12/r13 (same
; "stable base in rbx" idiom sema_expr.asm's struct_lit scratch region
; uses); r15 is likewise free and used here as an extra pair-local
; temporary (lhs type). Every one of rbx/r12/r13/r14/r15, whenever still
; needed later, is explicitly protected around each individual nested
; call below -- never assumed to simply survive it.
;
; Push-pattern per shape, pass 1 (address-vs-value/leaves ordering
; matters -- see codegen spec for why): SCALAR/BROADCAST = address then
; value; LITERAL = leaves (gen_init_push) then address, address pushed
; LAST; COPY = dest address then src address. Pass 2 (this pair's turn,
; overall pairs processed in reverse) undoes exactly that shape's
; ordering.
.assign:
    mov     r12, [rbx + AST_A_OFF]      ; pairs ptr
    mov     r13, [rbx + AST_B_OFF]      ; pair_count
    sub     rsp, MAX_LIST_ARITY * 24    ; scratch: 3 qwords per pair --
                                         ; shape tag, lhs type, cleanup
                                         ; size (COPY shape only, see
                                         ; .p1_maybe_copy/.p2_copy)
    mov     rbx, rsp                    ; rbx repurposed -- the original
                                         ; stmt node is never read again
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
    push    rbx
    push    r12
    push    r13
    push    r14
    call    gen_init_push               ; leaves pushed, forward order
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, [r12 + r14*8]          ; pair ptr, re-derive
    mov     rdi, [rax + AST_A_OFF]      ; lhs
    push    rbx
    push    r12
    push    r13
    push    r14
    call    gen_lvalue                  ; -> rax(ours) = lhs type; emits
                                         ; the address computation, AFTER
                                         ; the leaves (deliberately)
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r15, rax                    ; lhs type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; address pushed LAST
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r9, r14
    imul    r9, r9, 24
    add     r9, rbx                     ; r9 = this pair's scratch slot
                                         ; (r14*24 isn't a valid SIB scale)
    mov     qword [r9], 1               ; shape = LITERAL
    mov     [r9 + 8], r15
    jmp     .p1_next

.p1_not_literal:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_A_OFF]      ; lhs
    push    rbx
    push    r12
    push    r13
    push    r14
    call    gen_lvalue                  ; -> rax(ours) = lhs type; emits
                                         ; address computation
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r15, rax                    ; lhs type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; address pushed FIRST
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, r15
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    is_scalar_loadable_type
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    cmp     rax, 0
    je      .p1_composite
    ; --- SCALAR ---
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_B_OFF]      ; rhs
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    gen_rvalue                  ; -> target rax = value
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r9, r14
    imul    r9, r9, 24
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
    cmp     rcx, AST_EX_CALL
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
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    gen_lvalue                  ; -> rax(ours) = rhs type; r8
                                         ; (ours) = cleanup size (see
                                         ; gen_lvalue's own header);
                                         ; emits src address computation
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rax                         ; protect rhs type across
                                         ; types_equal ourselves
    push    r8                          ; cleanup -- same rule
    mov     rdi, rax
    mov     rsi, r15                    ; lhs type
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    types_equal
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    pop     r8                          ; cleanup back
    pop     rcx                         ; rhs type back
    cmp     rax, 0
    je      .p1_broadcast_composite_check
    ; --- COPY ---
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_str
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_nl                     ; src addr pushed (on top of the
                                         ; dest addr already pushed above)
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r9, r14
    imul    r9, r9, 24
    add     r9, rbx
    mov     qword [r9], 2               ; shape = COPY
    mov     [r9 + 8], r15
    mov     [r9 + 16], r8               ; cleanup, freed after the copy in
                                         ; pass 2 (see .p2_copy)
    jmp     .p1_next

.p1_broadcast_composite_check:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8                          ; cleanup -- protect it too, see
                                         ; header rule
    push    rcx                         ; rhs type -- protect across
                                         ; is_scalar_loadable_type below;
                                         ; rcx is never trustworthy across
                                         ; a call in this codebase (see
                                         ; type_size's own scratch use)
    mov     rdi, rcx
    call    is_scalar_loadable_type
    pop     rcx
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    cmp     rax, 0
    je      .p1_broadcast_unsupported
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    mov     rdi, rcx
    call    emit_sized_load             ; loads from (target) src addr
                                         ; into target rax
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    cmp     r8, 0
    je      .p1_broadcast_push
    mov     rsi, s_add_rsp_             ; free the temp this broadcast
    mov     rdx, s_add_rsp__len         ; source value was read out of,
    push    rbx                         ; now that we're done with it
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_str
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r8
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_dec
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .p1_broadcast_push
.p1_broadcast_scalar:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_B_OFF]
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    gen_rvalue                  ; -> target rax = value
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.p1_broadcast_push:
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     r9, r14
    imul    r9, r9, 24
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
    imul    r9, r9, 24
    add     r9, rbx
    mov     rax, [r9]                   ; shape tag
    mov     r15, [r9 + 8]               ; lhs type
    mov     r8, [r9 + 16]               ; cleanup size -- meaningful only
                                         ; for shape == 2 (COPY), see
                                         ; .p1_maybe_copy/.p2_copy
    cmp     rax, 0
    je      .p2_scalar
    cmp     rax, 1
    je      .p2_literal
    cmp     rax, 2
    je      .p2_copy
    ; shape == 3 (BROADCAST)
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; target rax = value
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; target rbx = address
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, [r15 + AST_A_OFF]      ; element type
    mov     rsi, [r15 + AST_B_OFF]      ; element count
    push    rbx
    push    r12
    push    r13
    push    r14
    call    gen_composite_broadcast
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .assign_pass2

.p2_scalar:
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; target rax = value
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; target rbx = address
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, r15
    push    rbx
    push    r12
    push    r13
    push    r14
    call    emit_sized_store
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .assign_pass2

.p2_literal:
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_str
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    call    emit_nl                     ; target rbx = address (pushed
                                         ; last in pass 1 for this shape)
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, [r12 + r14*8]          ; pair ptr, re-derive
    mov     rdi, [rax + AST_B_OFF]      ; rhs literal node
    mov     rsi, r15                    ; expected type = lhs type
    xor     rdx, rdx                    ; accumulated offset = 0
    push    rbx
    push    r12
    push    r13
    push    r14
    call    gen_init_pop_store
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    jmp     .assign_pass2

.p2_copy:
    mov     rsi, s_pop_rsi
    mov     rdx, s_pop_rsi_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_str
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_nl                     ; target rsi = src (pushed last)
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_pop_rdi
    mov     rdx, s_pop_rdi_len
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_str
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_nl                     ; target rdi = dest
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, r15
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r8
    call    type_size
    pop     r8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rdi, rax
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r8
    call    emit_rep_movsb_copy
    pop     r8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    cmp     r8, 0
    je      .p2_copy_done
    mov     rsi, s_add_rsp_             ; free the temp the src came from,
    mov     rdx, s_add_rsp__len         ; now that we're done reading it
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r8
    call    emit_str
    pop     r8
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r8
    push    rbx
    push    r12
    push    r13
    push    r14
    call    emit_dec
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r14
    call    emit_nl
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
.p2_copy_done:
    jmp     .assign_pass2

.assign_done:
    add     rsp, MAX_LIST_ARITY * 24
    jmp     .exit

.exit:
    ret

; ===========================================================================
; gen_block: in rdi = AST_BLOCK ptr. Generates every statement in it.
; ===========================================================================
gen_block:
    mov     rbx, rdi
    mov     r13, [rbx + AST_A_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_B_OFF]      ; stmt_count -- rbx itself is not
                                         ; read again after this point
    xor     rcx, rcx
.loop:
    cmp     rcx, r14
    jae     .done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    push    r13
    push    r14
    call    gen_stmt
    pop     r14
    pop     r13
    pop     rcx
    inc     rcx
    jmp     .loop
.done:
    ret

; ===========================================================================
; gen_func_block: in rdi = AST_FUNC_BLOCK ptr. Generates every decl's
; init, then every statement.
; ===========================================================================
gen_func_block:
    mov     rbx, rdi

    mov     r13, [rbx + AST_A_OFF]      ; decls ptr
    mov     r14, [rbx + AST_B_OFF]      ; decl_count
    xor     rcx, rcx
.decl_loop:
    cmp     rcx, r14
    jae     .decls_done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    push    rbx
    push    r13
    push    r14
    call    gen_decl
    pop     r14
    pop     r13
    pop     rbx
    pop     rcx
    inc     rcx
    jmp     .decl_loop
.decls_done:
    mov     r13, [rbx + AST_C_OFF]      ; stmts ptr
    mov     r14, [rbx + AST_D_OFF]      ; stmt_count -- rbx itself is not
                                         ; read again after this point
    xor     rcx, rcx
.stmt_loop:
    cmp     rcx, r14
    jae     .done
    push    rcx
    mov     rdi, [r13 + rcx*8]
    push    r13
    push    r14
    call    gen_stmt
    pop     r14
    pop     r13
    pop     rcx
    inc     rcx
    jmp     .stmt_loop
.done:
    ret
