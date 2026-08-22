; Postulate Stage 0 -- code generator: struct/array literals, plain
; composite-value copy, and array broadcast-init. See
; docs/postulate_stage0_codegen_spec.md.
;
; gen_init_push / gen_init_pop_store together implement STRUCT_LIT/
; ARRAY_LIT codegen -- used UNIFORMLY for decl-init, single-pair assign,
; and multi-pair simultaneous assign (no separate fast path): pass 1
; (gen_init_push) evaluates every leaf value, forward, structural order,
; and pushes each -- purely value computation, no addresses touched.
; The target base address is then computed and pushed *last* by the
; caller (decl/assign, after gen_init_push returns). Pass 2
; (gen_init_pop_store) is called by the caller after popping that base
; address into rbx; it walks the SAME structure in REVERSE order,
; offset accumulating as compile-time arithmetic, popping and storing
; each leaf via the retained rbx + a computed offset.
;
; Register-safety convention (applies to every routine in this file):
; no callee, including the trivial ones (emit_str/emit_dec/emit_nl), is
; ever trusted to leave any register untouched across a call. Whenever a
; value must survive a call, the function that needs it pushes it
; immediately before that one call and pops it immediately after -- never
; spanning more than one call per push/pop pair, so every call site is a
; self-contained, independently-checkable block.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern bytes_equal
extern lookup_struct
extern type_size
extern field_offset
extern gen_rvalue
extern codegen_fail
extern emit_str
extern emit_dec
extern emit_nl
extern next_label_suffix
extern emit_label_def
extern emit_label_ref
extern s_dotL
extern s_suf_end
extern s_suf_end_len

global gen_init_push
global gen_init_pop_store
global emit_sized_store_rbx_plus
global emit_rep_movsb_copy
global gen_composite_broadcast
global find_field_init

section .data
s_push_rax: db "    push    rax"
s_push_rax_len equ $ - s_push_rax
s_pop_rax: db "    pop     rax"
s_pop_rax_len equ $ - s_pop_rax

s_mov_byte_rbx_plus: db "    mov     byte [rbx + "
s_mov_byte_rbx_plus_len equ $ - s_mov_byte_rbx_plus
s_mov_word_rbx_plus: db "    mov     word [rbx + "
s_mov_word_rbx_plus_len equ $ - s_mov_word_rbx_plus
s_mov_dword_rbx_plus: db "    mov     dword [rbx + "
s_mov_dword_rbx_plus_len equ $ - s_mov_dword_rbx_plus
s_mov_qword_rbx_plus: db "    mov     qword [rbx + "
s_mov_qword_rbx_plus_len equ $ - s_mov_qword_rbx_plus
s_close_comma_al: db "], al"
s_close_comma_al_len equ $ - s_close_comma_al
s_close_comma_ax: db "], ax"
s_close_comma_ax_len equ $ - s_close_comma_ax
s_close_comma_eax: db "], eax"
s_close_comma_eax_len equ $ - s_close_comma_eax
s_close_comma_rax: db "], rax"
s_close_comma_rax_len equ $ - s_close_comma_rax

s_mov_rcx_: db "    mov     rcx, "
s_mov_rcx__len equ $ - s_mov_rcx_
s_cld: db "    cld"
s_cld_len equ $ - s_cld
s_rep_movsb: db "    rep     movsb"
s_rep_movsb_len equ $ - s_rep_movsb

s_mov_r12_rax: db "    mov     r12, rax"
s_mov_r12_rax_len equ $ - s_mov_r12_rax
s_cmp_rcx_0: db "    cmp     rcx, 0"
s_cmp_rcx_0_len equ $ - s_cmp_rcx_0
s_je_dotL: db "    je      "
s_je_dotL_len equ $ - s_je_dotL
s_jmp_dotL: db "    jmp     "
s_jmp_dotL_len equ $ - s_jmp_dotL
s_add_rbx_: db "    add     rbx, "
s_add_rbx__len equ $ - s_add_rbx_
s_dec_rcx: db "    dec     rcx"
s_dec_rcx_len equ $ - s_dec_rcx
s_mov_byte_rbx_r12b: db "    mov     byte [rbx], r12b"
s_mov_byte_rbx_r12b_len equ $ - s_mov_byte_rbx_r12b
s_mov_word_rbx_r12w: db "    mov     word [rbx], r12w"
s_mov_word_rbx_r12w_len equ $ - s_mov_word_rbx_r12w
s_mov_dword_rbx_r12d: db "    mov     dword [rbx], r12d"
s_mov_dword_rbx_r12d_len equ $ - s_mov_dword_rbx_r12d
s_mov_qword_rbx_r12: db "    mov     qword [rbx], r12"
s_mov_qword_rbx_r12_len equ $ - s_mov_qword_rbx_r12

s_suf_start: db "_start"
s_suf_start_len equ $ - s_suf_start

section .text

; ===========================================================================
; find_field_init: in rdi = AST_EX_STRUCT_LIT node, rsi = field
; name_offset, rdx = field name_len. out: rax = matching AST_FIELD_INIT
; node ptr, or 0 (defensive -- callers only invoke this for a field
; already validated present-exactly-once by the semantic checker).
; ===========================================================================
find_field_init:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                    ; struct_lit node
    mov     r12, rsi                    ; query name_offset
    mov     r13, rdx                    ; query name_len
    mov     rcx, [rbx + AST_D_OFF]      ; field_count
    mov     r8, [rbx + AST_C_OFF]       ; field_inits ptr
    xor     r9, r9                      ; index
.loop:
    cmp     r9, rcx
    jae     .not_found
    mov     rax, [r8 + r9*8]            ; AST_FIELD_INIT ptr
    cmp     qword [rax + AST_B_OFF], r13
    jne     .next
    push    rax
    push    r9
    push    rcx
    push    r8
    push    r12
    push    r13                         ; every one of our own live
                                         ; locals, protected by us across
                                         ; this one call -- next iteration
                                         ; needs all of them back
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, r12
    mov     rdx, r13
    call    bytes_equal
    mov     r10, rax                    ; match result -- protect across
                                         ; the pops below, which restore
                                         ; rax to the field_init ptr, not
                                         ; the comparison result
    pop     r13
    pop     r12
    pop     r8
    pop     rcx
    pop     r9
    pop     rax
    cmp     r10, 0
    jne     .found
.next:
    inc     r9
    jmp     .loop
.found:
    pop     r13
    pop     r12
    pop     rbx
    ret
.not_found:
    xor     rax, rax
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; emit_sized_store_rbx_plus: in rdi = type, rsi = offset. Emits a store
; of (the low N bytes of) the target program's rax into
; "[rbx + <offset>]", N per type_size, followed by a newline. Mirrors
; emit_sized_store (codegen_expr.asm) but for an offset base address --
; needed here because a single retained rbx serves many stores at
; different offsets within one composite literal.
; ===========================================================================
emit_sized_store_rbx_plus:
    push    r12
    push    r13
    mov     r12, rdi                    ; type -- only needed to build the
                                         ; type_size call below, never read
                                         ; again after it
    mov     r13, rsi                    ; offset
    push    r13
    call    type_size
    pop     r13
    cmp     rax, 1
    je      .b1
    cmp     rax, 2
    je      .b2
    cmp     rax, 4
    je      .b4
    mov     rsi, s_mov_qword_rbx_plus
    mov     rdx, s_mov_qword_rbx_plus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_close_comma_rax
    mov     rdx, s_close_comma_rax_len
    call    emit_str
    jmp     .done
.b1:
    mov     rsi, s_mov_byte_rbx_plus
    mov     rdx, s_mov_byte_rbx_plus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_close_comma_al
    mov     rdx, s_close_comma_al_len
    call    emit_str
    jmp     .done
.b2:
    mov     rsi, s_mov_word_rbx_plus
    mov     rdx, s_mov_word_rbx_plus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_close_comma_ax
    mov     rdx, s_close_comma_ax_len
    call    emit_str
    jmp     .done
.b4:
    mov     rsi, s_mov_dword_rbx_plus
    mov     rdx, s_mov_dword_rbx_plus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_close_comma_eax
    mov     rdx, s_close_comma_eax_len
    call    emit_str
.done:
    call    emit_nl
    pop     r13
    pop     r12
    ret

; ===========================================================================
; emit_rep_movsb_copy: in rdi = size in bytes (compile-time constant).
; Emits "mov rcx, <size>", "cld", "rep movsb" -- ASSUMES the caller has
; already emitted code setting the target program's rdi = dest address,
; rsi = src address (this routine never touches rdi/rsi itself, only
; text-emits the trailing copy instructions).
; ===========================================================================
emit_rep_movsb_copy:
    push    r12
    mov     r12, rdi
    mov     rsi, s_mov_rcx_
    mov     rdx, s_mov_rcx__len
    push    r12
    call    emit_str
    pop     r12
    mov     rax, r12                    ; r12's last use
    call    emit_dec
    call    emit_nl
    mov     rsi, s_cld
    mov     rdx, s_cld_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_rep_movsb
    mov     rdx, s_rep_movsb_len
    call    emit_str
    call    emit_nl
    pop     r12
    ret

; ===========================================================================
; gen_init_push: in rdi = AST_EX_STRUCT_LIT/AST_EX_ARRAY_LIT node. Pass 1
; of composite-literal codegen (ld. file header) -- walks the literal in
; forward, declaration/index order; for every leaf (scalar/pointer)
; field/element, gen_rvalue + push; a nested composite field/element is
; recursed into inline, joining the same flat push sequence. No
; addresses touched.
; ===========================================================================
gen_init_push:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_EX_STRUCT_LIT
    je      .struct
    ; AST_EX_ARRAY_LIT
    mov     r13, [rbx + AST_A_OFF]      ; elems ptr
    mov     r14, [rbx + AST_B_OFF]      ; elem_count
    xor     rcx, rcx
.arr_loop:
    cmp     rcx, r14
    jae     .done
    push    rcx
    mov     rax, [r13 + rcx*8]
    mov     rdx, [rax + AST_KIND_OFF]
    cmp     rdx, AST_EX_STRUCT_LIT
    je      .arr_recurse
    cmp     rdx, AST_EX_ARRAY_LIT
    je      .arr_recurse
    mov     rdi, rax
    push    r13
    push    r14                         ; next iteration needs both back
    call    gen_rvalue
    pop     r14
    pop     r13
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    push    r13
    push    r14
    call    emit_str
    pop     r14
    pop     r13
    push    r13
    push    r14
    call    emit_nl
    pop     r14
    pop     r13
    jmp     .arr_next
.arr_recurse:
    mov     rdi, rax
    push    r13
    push    r14
    call    gen_init_push
    pop     r14
    pop     r13
.arr_next:
    pop     rcx
    inc     rcx
    jmp     .arr_loop
.struct:
    mov     rdi, [rbx + AST_A_OFF]      ; name_offset
    mov     rsi, [rbx + AST_B_OFF]      ; name_len
    push    rbx                         ; needed by the loop below
    call    lookup_struct
    pop     rbx
    mov     r12, [rax + STE_DECL_PTR]   ; struct decl
    mov     r13, [r12 + AST_D_OFF]      ; field_count
    xor     rcx, rcx
.struct_loop:
    cmp     rcx, r13
    jae     .done
    push    rcx
    mov     rax, [r12 + AST_C_OFF]      ; fields ptr
    mov     rax, [rax + rcx*8]          ; AST_FIELD_DECL
    mov     rdi, rbx                    ; struct_lit node
    mov     rsi, [rax + AST_A_OFF]      ; field decl name_offset
    mov     rdx, [rax + AST_B_OFF]      ; field decl name_len
    push    rbx
    push    r12
    push    r13                         ; next iteration needs all three
    call    find_field_init
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, [rax + AST_C_OFF]      ; field_init's value node
    mov     rdx, [rax + AST_KIND_OFF]
    cmp     rdx, AST_EX_STRUCT_LIT
    je      .struct_recurse
    cmp     rdx, AST_EX_ARRAY_LIT
    je      .struct_recurse
    mov     rdi, rax
    push    rbx
    push    r12
    push    r13
    call    gen_rvalue
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    push    rbx
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    call    emit_nl
    pop     r13
    pop     r12
    pop     rbx
    jmp     .struct_next
.struct_recurse:
    mov     rdi, rax
    push    rbx
    push    r12
    push    r13
    call    gen_init_push
    pop     r13
    pop     r12
    pop     rbx
.struct_next:
    pop     rcx
    inc     rcx
    jmp     .struct_loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_init_pop_store: in rdi = AST_EX_STRUCT_LIT/AST_EX_ARRAY_LIT node,
; rsi = expected type of this literal (only actually consulted for
; AST_EX_ARRAY_LIT, to learn its element type/size -- AST_EX_STRUCT_LIT
; is self-describing via its own name), rdx = accumulated byte offset
; from the ultimate target base address (0 at the top-level call). Pass
; 2 of composite-literal codegen: PRECONDITION -- the target program's
; rbx already holds the ultimate target base address (popped by the
; caller from what gen_init_push's caller pushed -- ld. file header),
; and this routine never modifies it. Walks the SAME structure gen_init_push
; just walked, in REVERSE order, popping each leaf and storing it via
; emit_sized_store_rbx_plus(type, accumulated_offset + this leaf's own
; offset) -- a nested composite recurses with the combined offset, no
; further stack/address work needed since everything addresses off the
; one retained rbx.
; ===========================================================================
gen_init_pop_store:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; literal node (ours -- target's
                                         ; own rbx, the base address, is
                                         ; untouched by us the whole time)
    mov     r12, rsi                    ; expected type
    mov     r13, rdx                    ; accumulated offset
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_EX_STRUCT_LIT
    je      .struct
    ; AST_EX_ARRAY_LIT: r12 = array type -> element type/size. r12 is not
    ; needed again after this point in the array branch.
    mov     r14, [r12 + AST_A_OFF]      ; element type
    mov     rdi, r14
    push    rbx
    push    r13
    push    r14
    call    type_size
    pop     r14
    pop     r13
    pop     rbx
    mov     r15, rax                    ; element size
    mov     rax, [rbx + AST_B_OFF]      ; elem_count
    dec     rax                         ; start index = count - 1 (reverse)
.arr_loop:
    cmp     rax, 0
    jl      .done
    push    rax
    mov     rcx, [rbx + AST_A_OFF]      ; elems ptr
    mov     rcx, [rcx + rax*8]          ; this element node
    mov     rdx, [rcx + AST_KIND_OFF]
    ; this element's own offset = accumulated + index*elem_size
    mov     r8, rax
    imul    r8, r15
    add     r8, r13
    cmp     rdx, AST_EX_STRUCT_LIT
    je      .arr_recurse
    cmp     rdx, AST_EX_ARRAY_LIT
    je      .arr_recurse
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    push    rbx
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_str
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    push    rbx
    push    r13
    push    r14
    push    r15
    push    r8
    call    emit_nl
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    mov     rdi, r14                    ; element type
    mov     rsi, r8                     ; this element's offset
    push    rbx
    push    r13
    push    r14
    push    r15
    call    emit_sized_store_rbx_plus
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    jmp     .arr_next
.arr_recurse:
    mov     rdi, rcx                    ; nested literal node
    mov     rsi, r14                    ; element type (its own expected type)
    mov     rdx, r8                     ; combined offset
    push    rbx
    push    r13
    push    r14
    push    r15
    call    gen_init_pop_store
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
.arr_next:
    pop     rax
    dec     rax
    jmp     .arr_loop
.struct:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    push    rbx
    push    r13                         ; r12 is not needed again after
                                         ; this point in the struct branch
    call    lookup_struct
    pop     r13
    pop     rbx
    mov     r14, [rax + STE_DECL_PTR]   ; struct decl
    mov     rax, [r14 + AST_D_OFF]      ; field_count
    dec     rax                         ; start index = count - 1 (reverse)
.struct_loop:
    cmp     rax, 0
    jl      .done
    push    rax
    mov     rcx, [r14 + AST_C_OFF]      ; fields ptr
    mov     rcx, [rcx + rax*8]          ; this AST_FIELD_DECL
    push    rcx                         ; field decl ptr, saved across
                                         ; find_field_init the same way the
                                         ; original design already did --
                                         ; unrelated to our own protection
                                         ; below, just nested inside it
    mov     rdi, rbx                    ; struct_lit node
    mov     rsi, [rcx + AST_A_OFF]      ; field name_offset
    mov     rdx, [rcx + AST_B_OFF]      ; field name_len
    push    rbx
    push    r13
    push    r14
    call    find_field_init
    pop     r14
    pop     r13
    pop     rbx
    mov     r8, [rax + AST_C_OFF]       ; field_init's value node
    pop     rcx                         ; field decl ptr back
    push    rcx
    push    r8
    mov     rdi, r14                    ; struct decl
    mov     rsi, [rcx + AST_A_OFF]
    mov     rdx, [rcx + AST_B_OFF]
    push    rbx
    push    r13
    push    r14
    call    field_offset                ; -> rax = this field's local offset
    pop     r14
    pop     r13
    pop     rbx
    add     rax, r13                    ; combine with accumulated offset
    mov     r9, rax                     ; combined offset
    pop     r8                          ; value node
    pop     rcx                         ; field decl ptr
    mov     rdx, [r8 + AST_KIND_OFF]
    cmp     rdx, AST_EX_STRUCT_LIT
    je      .struct_recurse
    cmp     rdx, AST_EX_ARRAY_LIT
    je      .struct_recurse
    mov     r10, [rcx + AST_C_OFF]      ; field's declared type -- read
                                         ; while rcx is still valid, before
                                         ; anything below has a chance to
                                         ; disturb it
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    push    rbx
    push    r13
    push    r14
    push    r9
    push    r10
    call    emit_str
    pop     r10
    pop     r9
    pop     r14
    pop     r13
    pop     rbx
    push    rbx
    push    r13
    push    r14
    push    r9
    push    r10
    call    emit_nl
    pop     r10
    pop     r9
    pop     r14
    pop     r13
    pop     rbx
    mov     rdi, r10
    mov     rsi, r9
    push    rbx
    push    r13
    push    r14
    call    emit_sized_store_rbx_plus
    pop     r14
    pop     r13
    pop     rbx
    jmp     .struct_next
.struct_recurse:
    mov     rdi, r8                     ; nested literal node
    mov     rsi, [rcx + AST_C_OFF]      ; field's declared type
    mov     rdx, r9
    push    rbx
    push    r13
    push    r14
    call    gen_init_pop_store
    pop     r14
    pop     r13
    pop     rbx
.struct_next:
    pop     rax
    dec     rax
    jmp     .struct_loop
.done:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_composite_broadcast: in rdi = element type, rsi = element count.
; PRECONDITION: the target program's rax already holds the (scalar)
; value to broadcast, and rbx already holds the array's base address.
; Emits a runtime counted loop storing that one value into all N element
; slots -- the value is moved into the target's own r12 once (a register
; untouched by any other convention in this codegen), then each
; iteration stores a sized view of it and advances rbx by elem_size.
; ===========================================================================
gen_composite_broadcast:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                    ; element type (ours)
    mov     r12, rsi                    ; element count (ours)

    push    rbx
    push    r12
    call    next_label_suffix
    pop     r12
    pop     rbx
    mov     r13, rax                    ; unique suffix

    mov     rsi, s_mov_r12_rax
    mov     rdx, s_mov_r12_rax_len
    push    rbx
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    call    emit_nl
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_mov_rcx_
    mov     rdx, s_mov_rcx__len
    push    rbx
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r12                    ; r12's last use
    push    rbx
    push    r13
    call    emit_dec
    pop     r13
    pop     rbx
    push    rbx
    push    r13
    call    emit_nl
    pop     r13
    pop     rbx

    mov     rax, r13
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    push    rbx
    push    r13
    call    emit_label_def
    pop     r13
    pop     rbx

    mov     rsi, s_cmp_rcx_0
    mov     rdx, s_cmp_rcx_0_len
    push    rbx
    push    r13
    call    emit_str
    pop     r13
    pop     rbx
    push    rbx
    push    r13
    call    emit_nl
    pop     r13
    pop     rbx
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    push    rbx
    push    r13
    call    emit_str
    pop     r13
    pop     rbx
    mov     rax, r13
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    push    rbx
    push    r13
    call    emit_label_ref
    pop     r13
    pop     rbx
    push    rbx
    push    r13
    call    emit_nl
    pop     r13
    pop     rbx

    mov     rdi, rbx                    ; element type -- rbx's last use
    push    r13
    call    type_size
    pop     r13
    mov     r8, rax                     ; element size
    cmp     r8, 1
    je      .s1
    cmp     r8, 2
    je      .s2
    cmp     r8, 4
    je      .s4
    mov     rsi, s_mov_qword_rbx_r12
    mov     rdx, s_mov_qword_rbx_r12_len
    jmp     .store_emit
.s1:
    mov     rsi, s_mov_byte_rbx_r12b
    mov     rdx, s_mov_byte_rbx_r12b_len
    jmp     .store_emit
.s2:
    mov     rsi, s_mov_word_rbx_r12w
    mov     rdx, s_mov_word_rbx_r12w_len
    jmp     .store_emit
.s4:
    mov     rsi, s_mov_dword_rbx_r12d
    mov     rdx, s_mov_dword_rbx_r12d_len
.store_emit:
    push    r13
    push    r8
    call    emit_str
    pop     r8
    pop     r13
    push    r13
    push    r8
    call    emit_nl
    pop     r8
    pop     r13

    mov     rsi, s_add_rbx_
    mov     rdx, s_add_rbx__len
    push    r13
    push    r8
    call    emit_str
    pop     r8
    pop     r13
    mov     rax, r8                     ; r8's last use
    push    r13
    call    emit_dec
    pop     r13
    push    r13
    call    emit_nl
    pop     r13

    mov     rsi, s_dec_rcx
    mov     rdx, s_dec_rcx_len
    push    r13
    call    emit_str
    pop     r13
    push    r13
    call    emit_nl
    pop     r13

    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    mov     rsi, s_suf_start
    mov     rdx, s_suf_start_len
    push    r13
    call    emit_label_ref
    pop     r13
    push    r13
    call    emit_nl
    pop     r13

    mov     rax, r13                    ; r13's final use
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def

    pop     r13
    pop     r12
    pop     rbx
    ret
