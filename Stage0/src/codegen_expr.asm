; Postulate Stage 0 -- code generator: expression codegen + shared emission
; helpers. See docs/postulate_stage0_codegen_spec.md.
;
; gen_rvalue(node) -> value in rax. gen_lvalue(node) -> address in rbx.
; Phase 2: struct/array/pointer locals fully supported (INDEX/FIELD/
; UNARY(*)/UNARY(&) all implemented, composably); calls to both extern
; syscalls and user functions (incl. recursion) -- but a struct/array
; value may never cross a function-call boundary (as an argument or a
; return value), only exist as a local/param/field/element -- that's a
; separate, not-yet-designed future phase (ld. codegen spec). Anything
; outside scope hits codegen_fail with a clear diagnostic rather than
; emitting wrong code.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern lookup_local
extern lookup_callable
extern lookup_struct
extern type_size
extern is_signed_type
extern is_scalar_loadable_type
extern field_offset
extern field_type
extern local_stack_offset
extern get_bool_type
extern get_int_type
extern bytes_equal
extern ast_alloc_node

global gen_rvalue
global gen_lvalue
global gen_named_local_addr
global gen_user_call
global codegen_fail
global emit_dec
global emit_nl
global next_label_suffix
global emit_label_num
global emit_label_def
global emit_label_ref
global emit_sized_load
global emit_sized_store
global s_dotL
global s_suf_false
global s_suf_false_len
global s_suf_true
global s_suf_true_len
global s_suf_end
global s_suf_end_len
global s_suf_else
global s_suf_else_len
global s_suf_start
global s_suf_start_len
global s_je_dotL
global s_je_dotL_len
global s_jne_dotL
global s_jne_dotL_len
global s_jmp_dotL
global s_jmp_dotL_len
global s_cmp_rax_0
global s_cmp_rax_0_len

section .bss
label_counter: resq 1

section .data
msg_codegen_prefix: db "codegen error: "
msg_codegen_prefix_len equ $ - msg_codegen_prefix
nl_byte: db 10

msg_unsupported_expr: db "expression construct not supported by this codegen phase (struct/array/pointer/user-function-call/deferred feature)"
msg_unsupported_expr_len equ $ - msg_unsupported_expr

s_mov_rax_: db "    mov     rax, "
s_mov_rax__len equ $ - s_mov_rax_
s_mov_rbx_: db "    mov     rbx, "
s_mov_rbx__len equ $ - s_mov_rbx_
s_mov_rbx_rax: db "    mov     rbx, rax"
s_mov_rbx_rax_len equ $ - s_mov_rbx_rax
s_mov_rax_rbx: db "    mov     rax, rbx"
s_mov_rax_rbx_len equ $ - s_mov_rax_rbx
s_lea_rbx_rbp_minus: db "    lea     rbx, [rbp - "
s_lea_rbx_rbp_minus_len equ $ - s_lea_rbx_rbp_minus
s_close_bracket: db "]"
s_close_bracket_len equ $ - s_close_bracket
s_push_rax: db "    push    rax"
s_push_rax_len equ $ - s_push_rax
s_push_rbx: db "    push    rbx"
s_push_rbx_len equ $ - s_push_rbx
s_pop_rax: db "    pop     rax"
s_pop_rax_len equ $ - s_pop_rax
s_pop_rbx: db "    pop     rbx"
s_pop_rbx_len equ $ - s_pop_rbx
s_mov_rcx_rax: db "    mov     rcx, rax"
s_mov_rcx_rax_len equ $ - s_mov_rcx_rax
s_neg_rax: db "    neg     rax"
s_neg_rax_len equ $ - s_neg_rax
s_xor_rax_1: db "    xor     rax, 1"
s_xor_rax_1_len equ $ - s_xor_rax_1

s_add_rax_rcx: db "    add     rax, rcx"
s_add_rax_rcx_len equ $ - s_add_rax_rcx
s_sub_rax_rcx: db "    sub     rax, rcx"
s_sub_rax_rcx_len equ $ - s_sub_rax_rcx
s_imul_rax_rcx: db "    imul    rax, rcx"
s_imul_rax_rcx_len equ $ - s_imul_rax_rcx
s_and_rax_rcx: db "    and     rax, rcx"
s_and_rax_rcx_len equ $ - s_and_rax_rcx
s_or_rax_rcx: db "    or      rax, rcx"
s_or_rax_rcx_len equ $ - s_or_rax_rcx
s_xor_rax_rcx: db "    xor     rax, rcx"
s_xor_rax_rcx_len equ $ - s_xor_rax_rcx
s_shl_rax_cl: db "    shl     rax, cl"
s_shl_rax_cl_len equ $ - s_shl_rax_cl
s_sar_rax_cl: db "    sar     rax, cl"
s_sar_rax_cl_len equ $ - s_sar_rax_cl
s_shr_rax_cl: db "    shr     rax, cl"
s_shr_rax_cl_len equ $ - s_shr_rax_cl
s_cqo: db "    cqo"
s_cqo_len equ $ - s_cqo
s_xor_rdx_rdx: db "    xor     rdx, rdx"
s_xor_rdx_rdx_len equ $ - s_xor_rdx_rdx
s_idiv_rcx: db "    idiv    rcx"
s_idiv_rcx_len equ $ - s_idiv_rcx
s_div_rcx: db "    div     rcx"
s_div_rcx_len equ $ - s_div_rcx
s_mov_rax_rdx: db "    mov     rax, rdx"
s_mov_rax_rdx_len equ $ - s_mov_rax_rdx
s_cmp_rax_rcx: db "    cmp     rax, rcx"
s_cmp_rax_rcx_len equ $ - s_cmp_rax_rcx
s_movzx_rax_al: db "    movzx   rax, al"
s_movzx_rax_al_len equ $ - s_movzx_rax_al

s_sete_al:  db "    sete    al"
s_sete_al_len equ $ - s_sete_al
s_setne_al: db "    setne   al"
s_setne_al_len equ $ - s_setne_al
s_setl_al:  db "    setl    al"
s_setl_al_len equ $ - s_setl_al
s_setg_al:  db "    setg    al"
s_setg_al_len equ $ - s_setg_al
s_setle_al: db "    setle   al"
s_setle_al_len equ $ - s_setle_al
s_setge_al: db "    setge   al"
s_setge_al_len equ $ - s_setge_al
s_setb_al:  db "    setb    al"
s_setb_al_len equ $ - s_setb_al
s_seta_al:  db "    seta    al"
s_seta_al_len equ $ - s_seta_al
s_setbe_al: db "    setbe   al"
s_setbe_al_len equ $ - s_setbe_al
s_setae_al: db "    setae   al"
s_setae_al_len equ $ - s_setae_al

s_cmp_rax_0: db "    cmp     rax, 0"
s_cmp_rax_0_len equ $ - s_cmp_rax_0
; NOTE: these three intentionally do NOT include ".L" -- emit_label_ref
; supplies that itself (via s_dotL below); baking it in here as well
; would double it (".L.L5_else") wherever a jump target is emitted.
s_je_dotL: db "    je      "
s_je_dotL_len equ $ - s_je_dotL
s_jne_dotL: db "    jne     "
s_jne_dotL_len equ $ - s_jne_dotL
s_jmp_dotL: db "    jmp     "
s_jmp_dotL_len equ $ - s_jmp_dotL
s_mov_rax_0: db "    mov     rax, 0"
s_mov_rax_0_len equ $ - s_mov_rax_0
s_mov_rax_1: db "    mov     rax, 1"
s_mov_rax_1_len equ $ - s_mov_rax_1
s_colon_nl: db ":", 10
s_colon_nl_len equ $ - s_colon_nl
s_underscore: db "_"
s_underscore_len equ $ - s_underscore
s_dotL: db ".L"
s_dotL_len equ $ - s_dotL
s_rbx_bracket: db "[rbx]"
s_rbx_bracket_len equ $ - s_rbx_bracket

; sized loads, signed (movsx) / unsigned (movzx), by width
s_movsx_rax_byte:  db "    movsx   rax, byte "
s_movsx_rax_byte_len equ $ - s_movsx_rax_byte
s_movzx_rax_byte:  db "    movzx   rax, byte "
s_movzx_rax_byte_len equ $ - s_movzx_rax_byte
s_movsx_rax_word:  db "    movsx   rax, word "
s_movsx_rax_word_len equ $ - s_movsx_rax_word
s_movzx_rax_word:  db "    movzx   rax, word "
s_movzx_rax_word_len equ $ - s_movzx_rax_word
s_movsxd_rax_dword: db "    movsxd  rax, dword "
s_movsxd_rax_dword_len equ $ - s_movsxd_rax_dword
s_mov_eax_dword: db "    mov     eax, dword "
s_mov_eax_dword_len equ $ - s_mov_eax_dword
s_mov_rax_qword: db "    mov     rax, qword "
s_mov_rax_qword_len equ $ - s_mov_rax_qword

; stores, by width
s_mov_byte_ptr:  db "    mov     byte "
s_mov_byte_ptr_len equ $ - s_mov_byte_ptr
s_comma_al: db ", al"
s_comma_al_len equ $ - s_comma_al
s_mov_word_ptr:  db "    mov     word "
s_mov_word_ptr_len equ $ - s_mov_word_ptr
s_comma_ax: db ", ax"
s_comma_ax_len equ $ - s_comma_ax
s_mov_dword_ptr: db "    mov     dword "
s_mov_dword_ptr_len equ $ - s_mov_dword_ptr
s_comma_eax: db ", eax"
s_comma_eax_len equ $ - s_comma_eax
s_mov_qword_ptr: db "    mov     qword "
s_mov_qword_ptr_len equ $ - s_mov_qword_ptr
s_comma_rax: db ", rax"
s_comma_rax_len equ $ - s_comma_rax

; extern/syscall shim
s_pop_rdi: db "    pop     rdi"
s_pop_rdi_len equ $ - s_pop_rdi
s_pop_rsi: db "    pop     rsi"
s_pop_rsi_len equ $ - s_pop_rsi
s_pop_rdx: db "    pop     rdx"
s_pop_rdx_len equ $ - s_pop_rdx
s_pop_rcx: db "    pop     rcx"
s_pop_rcx_len equ $ - s_pop_rcx
s_mov_r10_rcx: db "    mov     r10, rcx"
s_mov_r10_rcx_len equ $ - s_mov_r10_rcx
s_pop_r8: db "    pop     r8"
s_pop_r8_len equ $ - s_pop_r8
s_pop_r9: db "    pop     r9"
s_pop_r9_len equ $ - s_pop_r9
s_syscall: db "    syscall"
s_syscall_len equ $ - s_syscall

str_sys_read:  db "sys_read"
str_sys_write: db "sys_write"
str_sys_mmap:  db "sys_mmap"
str_sys_exit:  db "sys_exit"
msg_unknown_extern: db "codegen internal error: extern function not on the recognized syscall whitelist (should have been rejected by the semantic checker)"
msg_unknown_extern_len equ $ - msg_unknown_extern

s_suf_false: db "_false"
s_suf_false_len equ $ - s_suf_false
s_suf_true: db "_true"
s_suf_true_len equ $ - s_suf_true
s_suf_end: db "_end"
s_suf_end_len equ $ - s_suf_end
s_suf_else: db "_else"
s_suf_else_len equ $ - s_suf_else
s_suf_start: db "_start"
s_suf_start_len equ $ - s_suf_start
s_empty: db ""
s_empty_len equ 0

s_imul_rax_: db "    imul    rax, "
s_imul_rax__len equ $ - s_imul_rax_
s_add_rbx_rax: db "    add     rbx, rax"
s_add_rbx_rax_len equ $ - s_add_rbx_rax
s_add_rbx_: db "    add     rbx, "
s_add_rbx__len equ $ - s_add_rbx_

msg_composite_as_scalar: db "cannot use a struct/array value directly as a scalar expression -- use its fields/elements, or copy it via a full assignment"
msg_composite_as_scalar_len equ $ - msg_composite_as_scalar
msg_composite_call_boundary: db "struct/array values cannot be passed as a call argument or returned from a function in this codegen phase yet"
msg_composite_call_boundary_len equ $ - msg_composite_call_boundary

s_mov_rdi_rsp: db "    mov     rdi, rsp"
s_mov_rdi_rsp_len equ $ - s_mov_rdi_rsp
s_mov_rsi_: db "    mov     rsi, "
s_mov_rsi__len equ $ - s_mov_rsi_
s_call_pf_: db "    call    pf_"
s_call_pf__len equ $ - s_call_pf_
s_add_rsp_: db "    add     rsp, "
s_add_rsp__len equ $ - s_add_rsp_

section .text

; ===========================================================================
; codegen_fail: in rsi = message ptr, rdx = message len. Writes "codegen
; error: <msg>\n" to stderr and exits with code 4 (a new exit-code class,
; ld. the codegen spec's exit-code table -- distinct from 1/2/3, since this
; is neither a parse nor a semantic error: the program is valid Postulate,
; just outside what this phase of the code generator implements yet).
; Never returns.
; ===========================================================================
codegen_fail:
    push    rbx
    push    r12
    mov     rbx, rsi
    mov     r12, rdx
    mov     qword [err_cursor], 0
    mov     rsi, msg_codegen_prefix
    mov     rdx, msg_codegen_prefix_len
    call    err_append_str
    mov     rsi, rbx
    mov     rdx, r12
    call    err_append_str
    mov     rsi, nl_byte
    mov     rdx, 1
    call    err_append_str
    mov     rdi, 2
    mov     rsi, err_buf
    mov     rdx, [err_cursor]
    call    write_all
    mov     rax, 60
    mov     rdi, 4
    syscall

; ===========================================================================
; emit_dec: in rax = unsigned value. Appends decimal ASCII to stdout via
; emit_str. Local copy of ast_dump.asm's routine of the same name -- safe,
; build/codegen never links ast_dump.o.
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

; ===========================================================================
; emit_nl: appends a single newline to stdout.
; ===========================================================================
emit_nl:
    mov     rsi, nl_byte
    mov     rdx, 1
    jmp     emit_str

; ===========================================================================
; next_label_suffix: out rax = a fresh integer, unique for the whole
; emitted file -- the shared counter behind every ".L<N>..." label.
; ===========================================================================
next_label_suffix:
    mov     rax, [label_counter]
    inc     qword [label_counter]
    ret

; ===========================================================================
; emit_label_num: in rax = label suffix integer. Appends ".L<N>" (no
; trailing colon/newline -- callers append whatever follows, e.g.
; "_else:\n" or "\n" for a jump target reference).
; ===========================================================================
emit_label_num:
    push    rbx
    mov     rbx, rax
    mov     rsi, s_dotL
    mov     rdx, s_dotL_len
    call    emit_str
    mov     rax, rbx
    call    emit_dec
    pop     rbx
    ret

; ===========================================================================
; emit_sized_load: internal, global (used by codegen_stmt.asm/
; codegen_program.asm too). in rbx = address (from gen_lvalue), rdi = the
; value's declared type node. Emits a load of [rbx] into rax, sign/zero-
; extended per type_size/is_signed_type, followed by a newline. rbx itself
; is untouched (only ever read, never used as scratch here).
; ===========================================================================
emit_sized_load:
    push    r12
    push    r13
    mov     r12, rdi                    ; type node
    call    type_size
    mov     r13, rax                    ; size -- NOT rcx: a second call
                                         ; (is_signed_type) follows before
                                         ; this is consumed, and rcx isn't
                                         ; provably safe across any call
                                         ; here (ld. type_size's own rcx
                                         ; scratch use, same lesson as
                                         ; field_offset)
    mov     rdi, r12
    call    is_signed_type
    mov     rdx, rax                    ; signed?
    cmp     r13, 1
    je      .b1
    cmp     r13, 2
    je      .b2
    cmp     r13, 4
    je      .b4
    jmp     .b8
.b1:
    cmp     rdx, 0
    je      .b1u
    mov     rsi, s_movsx_rax_byte
    mov     rdx, s_movsx_rax_byte_len
    jmp     .emit
.b1u:
    mov     rsi, s_movzx_rax_byte
    mov     rdx, s_movzx_rax_byte_len
    jmp     .emit
.b2:
    cmp     rdx, 0
    je      .b2u
    mov     rsi, s_movsx_rax_word
    mov     rdx, s_movsx_rax_word_len
    jmp     .emit
.b2u:
    mov     rsi, s_movzx_rax_word
    mov     rdx, s_movzx_rax_word_len
    jmp     .emit
.b4:
    cmp     rdx, 0
    je      .b4u
    mov     rsi, s_movsxd_rax_dword
    mov     rdx, s_movsxd_rax_dword_len
    jmp     .emit
.b4u:
    mov     rsi, s_mov_eax_dword
    mov     rdx, s_mov_eax_dword_len
    jmp     .emit
.b8:
    mov     rsi, s_mov_rax_qword
    mov     rdx, s_mov_rax_qword_len
.emit:
    call    emit_str
    mov     rsi, s_rbx_bracket
    mov     rdx, s_rbx_bracket_len
    call    emit_str
    call    emit_nl
    pop     r13
    pop     r12
    ret

; ===========================================================================
; emit_sized_store: internal, global. in rbx = target address (from
; gen_lvalue), rax = value already computed (from gen_rvalue), rdi = the
; target's declared type node. Emits a store of (the low N bytes of) rax
; into [rbx], N per type_size, followed by a newline. Value must already
; be in rax and address already in rbx when called -- callers are
; responsible for that ordering (ld. AST_STMT_ASSIGN's two-pass scheme).
; ===========================================================================
emit_sized_store:
    push    r12
    mov     r12, rdi
    call    type_size
    cmp     rax, 1
    je      .b1
    cmp     rax, 2
    je      .b2
    cmp     rax, 4
    je      .b4
    mov     rsi, s_mov_qword_ptr
    mov     rdx, s_mov_qword_ptr_len
    call    emit_str
    mov     rsi, s_rbx_bracket
    mov     rdx, s_rbx_bracket_len
    call    emit_str
    mov     rsi, s_comma_rax
    mov     rdx, s_comma_rax_len
    call    emit_str
    jmp     .done
.b1:
    mov     rsi, s_mov_byte_ptr
    mov     rdx, s_mov_byte_ptr_len
    call    emit_str
    mov     rsi, s_rbx_bracket
    mov     rdx, s_rbx_bracket_len
    call    emit_str
    mov     rsi, s_comma_al
    mov     rdx, s_comma_al_len
    call    emit_str
    jmp     .done
.b2:
    mov     rsi, s_mov_word_ptr
    mov     rdx, s_mov_word_ptr_len
    call    emit_str
    mov     rsi, s_rbx_bracket
    mov     rdx, s_rbx_bracket_len
    call    emit_str
    mov     rsi, s_comma_ax
    mov     rdx, s_comma_ax_len
    call    emit_str
    jmp     .done
.b4:
    mov     rsi, s_mov_dword_ptr
    mov     rdx, s_mov_dword_ptr_len
    call    emit_str
    mov     rsi, s_rbx_bracket
    mov     rdx, s_rbx_bracket_len
    call    emit_str
    mov     rsi, s_comma_eax
    mov     rdx, s_comma_eax_len
    call    emit_str
.done:
    call    emit_nl
    pop     r12
    ret

; ===========================================================================
; emit_label_def / emit_label_ref: in rax = label suffix integer, rsi =
; suffix-text ptr, rdx = suffix-text len (0-length s_empty for none).
; emit_label_def appends ".L<N><suffix>:\n" (a label definition line).
; emit_label_ref appends ".L<N><suffix>" (no colon/newline -- for use right
; after a jump mnemonic like "    je      "). Shared by &&/||'s short-
; circuit codegen here and by codegen_stmt.asm's if/while.
; ===========================================================================
emit_label_def:
    push    rbx
    push    r12
    mov     rbx, rax
    mov     r12, rsi
    push    rdx
    mov     rsi, s_dotL
    mov     rdx, s_dotL_len
    call    emit_str
    mov     rax, rbx
    call    emit_dec
    pop     rdx
    mov     rsi, r12
    call    emit_str
    mov     rsi, s_colon_nl
    mov     rdx, s_colon_nl_len
    call    emit_str
    pop     r12
    pop     rbx
    ret

emit_label_ref:
    push    rbx
    push    r12
    mov     rbx, rax
    mov     r12, rsi
    push    rdx
    mov     rsi, s_dotL
    mov     rdx, s_dotL_len
    call    emit_str
    mov     rax, rbx
    call    emit_dec
    pop     rdx
    mov     rsi, r12
    call    emit_str
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_lvalue: in rdi = expr node ptr. out: rax = the lvalue's type node
; ptr. Emits code that leaves the lvalue's address in the emitted
; program's rbx. Phase 1 scope: AST_EX_IDENT only (INDEX/FIELD/UNARY(*)
; are deferred -- struct/array/pointer codegen, ld. codegen spec).
; Note on two worlds: this routine (like every routine in this file) uses
; rbx/r12-r15 as ITS OWN compile-time bookkeeping registers, per this
; codebase's universal convention -- entirely separate from "rbx" in the
; comment above, which refers to the EMITTED assembly text's runtime
; register, read back only by whatever emits "[rbx]" afterward
; (emit_sized_load/emit_sized_store).
; ===========================================================================
gen_lvalue:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .ident
    cmp     rax, AST_EX_INDEX
    je      .index
    cmp     rax, AST_EX_FIELD
    je      .field
    cmp     rax, AST_EX_UNARY
    je      .unary_deref
    mov     rsi, msg_unsupported_expr
    mov     rdx, msg_unsupported_expr_len
    call    codegen_fail
.ident:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    gen_named_local_addr
    jmp     .exit

; INDEX: gen_lvalue(base) -> rbx; push rbx; gen_rvalue(index) -> rax;
; imul rax, elem_size; pop rbx; add rbx, rax. Correct uniformly whether
; base is a plain array local or a dereferenced pointer-to-array -- both
; resolve through the same UNARY(*)/IDENT lvalue rules, no special-casing.
.index:
    mov     rdi, [rbx + AST_A_OFF]      ; base
    call    gen_lvalue                  ; -> target rbx = base addr;
                                         ; rax(ours) = base type (an array)
    mov     r12, rax                    ; base (array) type
    mov     rsi, s_push_rbx
    mov     rdx, s_push_rbx_len
    call    emit_str
    call    emit_nl
    mov     rdi, [rbx + AST_B_OFF]      ; index expr
    call    gen_rvalue                  ; -> target rax = index value
    mov     rdi, [r12 + AST_A_OFF]      ; element type
    call    type_size                   ; pure compile-time computation --
                                         ; doesn't touch the target's rax
    mov     r13, rax                    ; elem_size -- rcx is NOT safe
                                         ; across emit_str (it's emit_str's
                                         ; own copy-loop counter, always
                                         ; left at 0)
    mov     rsi, s_imul_rax_
    mov     rdx, s_imul_rax__len
    call    emit_str
    mov     rax, r13
    call    emit_dec
    call    emit_nl
    mov     rsi, s_pop_rbx
    mov     rdx, s_pop_rbx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_add_rbx_rax
    mov     rdx, s_add_rbx_rax_len
    call    emit_str
    call    emit_nl
    mov     rax, [r12 + AST_A_OFF]      ; result type = element type
    jmp     .exit

; FIELD: base always resolves to a struct type by construction (semantics
; already rejects field access through a pointer without an explicit *).
.field:
    mov     rdi, [rbx + AST_A_OFF]      ; base
    call    gen_lvalue                  ; -> target rbx = base addr;
                                         ; rax(ours) = base type (a
                                         ; struct-name AST_TY_BASE)
    mov     rdi, [rax + AST_B_OFF]      ; struct name_offset
    mov     rsi, [rax + AST_C_OFF]      ; struct name_len
    call    lookup_struct
    mov     r12, [rax + STE_DECL_PTR]   ; struct decl
    mov     rdi, r12
    mov     rsi, [rbx + AST_B_OFF]      ; field name_offset
    mov     rdx, [rbx + AST_C_OFF]      ; field name_len
    call    field_offset
    mov     r13, rax                    ; offset -- rcx is NOT safe here,
                                         ; emit_str clobbers it as its own
                                         ; copy-loop counter (and always
                                         ; leaves it at 0, which is why
                                         ; this looked like "every field
                                         ; is at offset 0" when it used
                                         ; rcx instead)
    mov     rsi, s_add_rbx_
    mov     rdx, s_add_rbx__len
    call    emit_str
    mov     rax, r13
    call    emit_dec
    call    emit_nl
    mov     rdi, r12
    mov     rsi, [rbx + AST_B_OFF]
    mov     rdx, [rbx + AST_C_OFF]
    call    field_type                  ; -> rax = field's declared type
    jmp     .exit

; UNARY(*): the pointer's own VALUE already *is* the target address.
.unary_deref:
    mov     rax, [rbx + AST_A_OFF]      ; op
    cmp     rax, TOK_STAR
    je      .deref_ok
    mov     rsi, msg_unsupported_expr
    mov     rdx, msg_unsupported_expr_len
    call    codegen_fail
.deref_ok:
    mov     rdi, [rbx + AST_B_OFF]      ; operand (the pointer expr)
    call    gen_rvalue                  ; -> target rax = pointer value;
                                         ; rax(ours) = pointer type
    mov     r12, rax
    mov     rsi, s_mov_rbx_rax
    mov     rdx, s_mov_rbx_rax_len
    call    emit_str
    call    emit_nl
    mov     rax, [r12 + AST_A_OFF]      ; result type = pointee type
    jmp     .exit

.exit:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_named_local_addr: in rdi = name_offset, rsi = name_len (of some
; already-registered local -- a param or func_block decl). out: rax = its
; declared type node ptr. Emits "lea rbx, [rbp - N]\n", N = its stack
; offset. Shared by gen_lvalue's AST_EX_IDENT case and codegen_stmt.asm's
; gen_decl -- AST_EX_IDENT and AST_DECL_MUT/AST_DECL_CONST all share the
; same a=name_offset/b=name_len prefix layout, so both reach this exact
; same address computation, just via different node kinds.
; ===========================================================================
gen_named_local_addr:
    push    r12
    push    r13
    call    lookup_local
    mov     r12, rax                    ; local_table entry ptr
    mov     rdi, r12
    call    local_stack_offset
    mov     r13, rax                    ; offset, protected across emit_str
    mov     rsi, s_lea_rbx_rbp_minus
    mov     rdx, s_lea_rbx_rbp_minus_len
    call    emit_str
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_close_bracket
    mov     rdx, s_close_bracket_len
    call    emit_str
    call    emit_nl
    mov     rax, [r12 + LTE_TYPE_PTR]
    pop     r13
    pop     r12
    ret

; ===========================================================================
; gen_rvalue: in rdi = expr node ptr. out: rax = the expression's type
; node ptr. Emits code that leaves the computed value in the emitted
; program's rax. Phase 1 scope: literals, IDENT, unary -/!, all binary
; ops (incl. &&/|| short-circuit), and calls to whitelisted extern
; syscalls -- everything else (INDEX/FIELD/unary */&, user-function
; calls, STRUCT_LIT/ARRAY_LIT) hits codegen_fail.
; ===========================================================================
gen_rvalue:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_EX_INT
    je      .int
    cmp     rax, AST_EX_BOOL
    je      .bool
    cmp     rax, AST_EX_NULL
    je      .null
    cmp     rax, AST_EX_IDENT
    je      .load_via_lvalue
    cmp     rax, AST_EX_INDEX
    je      .load_via_lvalue
    cmp     rax, AST_EX_FIELD
    je      .load_via_lvalue
    cmp     rax, AST_EX_UNARY
    je      .unary
    cmp     rax, AST_EX_BINARY
    je      .binary
    cmp     rax, AST_EX_CALL
    je      .call
    mov     rsi, msg_unsupported_expr
    mov     rdx, msg_unsupported_expr_len
    call    codegen_fail

.int:
    mov     rsi, s_mov_rax_
    mov     rdx, s_mov_rax__len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]
    call    emit_dec
    call    emit_nl
    call    get_int_type
    jmp     .exit

.bool:
    mov     rax, [rbx + AST_A_OFF]
    cmp     rax, 0
    jne     .bool_true
    mov     rsi, s_mov_rax_0
    mov     rdx, s_mov_rax_0_len
    jmp     .bool_emit
.bool_true:
    mov     rsi, s_mov_rax_1
    mov     rdx, s_mov_rax_1_len
.bool_emit:
    call    emit_str
    call    emit_nl
    call    get_bool_type
    jmp     .exit

.null:
    mov     rsi, s_mov_rax_0
    mov     rdx, s_mov_rax_0_len
    call    emit_str
    call    emit_nl
    call    get_int_type                ; placeholder type -- unreachable
                                         ; in a well-typed scalar-only
                                         ; program, ld. spec
    jmp     .exit

; IDENT/INDEX/FIELD all reach their value the same way: compute the
; lvalue (address into target rbx), guard that its type actually fits
; in a single register (ld. is_scalar_loadable_type -- without this, a
; struct that happens to be exactly 1/2/4/8 bytes would silently fall
; through emit_sized_load's width dispatch and get "loaded" as if it
; were a plain scalar), then load it.
.load_via_lvalue:
    mov     rdi, rbx
    call    gen_lvalue                  ; -> rax = type; emits address calc
    mov     r12, rax
    mov     rdi, r12
    call    is_scalar_loadable_type
    cmp     rax, 0
    jne     .load_ok
    mov     rsi, msg_composite_as_scalar
    mov     rdx, msg_composite_as_scalar_len
    call    codegen_fail
.load_ok:
    mov     rdi, r12
    call    emit_sized_load             ; emits "<mov/movsx/movzx> rax, ... [rbx]"
    mov     rax, r12
    jmp     .exit

.unary:
    mov     rax, [rbx + AST_A_OFF]      ; op
    cmp     rax, TOK_MINUS
    je      .neg
    cmp     rax, TOK_BANG
    je      .lnot
    cmp     rax, TOK_STAR
    je      .deref
    cmp     rax, TOK_AMP
    je      .addr
    mov     rsi, msg_unsupported_expr
    mov     rdx, msg_unsupported_expr_len
    call    codegen_fail
.neg:
    mov     rdi, [rbx + AST_B_OFF]
    call    gen_rvalue
    mov     r12, rax
    mov     rsi, s_neg_rax
    mov     rdx, s_neg_rax_len
    call    emit_str
    call    emit_nl
    mov     rax, r12
    jmp     .exit
.lnot:
    mov     rdi, [rbx + AST_B_OFF]
    call    gen_rvalue
    mov     rsi, s_xor_rax_1
    mov     rdx, s_xor_rax_1_len
    call    emit_str
    call    emit_nl
    call    get_bool_type
    jmp     .exit

; UNARY(*) rvalue: gen_lvalue (-> rbx), then a guarded sized load, same
; shape as .load_via_lvalue above (this IS the "load via lvalue" case
; for UNARY(*), just reached via a different node kind).
.deref:
    mov     rdi, rbx                    ; the UNARY(*) node itself
    call    gen_lvalue                  ; -> rax = pointee type; emits
                                         ; address calc into target rbx
    mov     r12, rax
    mov     rdi, r12
    call    is_scalar_loadable_type
    cmp     rax, 0
    jne     .deref_ok
    mov     rsi, msg_composite_as_scalar
    mov     rdx, msg_composite_as_scalar_len
    call    codegen_fail
.deref_ok:
    mov     rdi, r12
    call    emit_sized_load
    mov     rax, r12
    jmp     .exit

; UNARY(&): rvalue only (can't be re-addressed). gen_lvalue(operand) ->
; rbx; that address *is* the result, transferred into rax. Result type
; is always a pointer, synthesized fresh exactly like sema_expr.asm's
; own .unary_addr case does at check time.
.addr:
    mov     rdi, [rbx + AST_B_OFF]      ; operand
    call    gen_lvalue                  ; -> rax(ours) = operand type;
                                         ; emits address calc into target rbx
    mov     r12, rax                    ; operand type, saved before the
                                         ; ast_alloc_node call below needs
                                         ; rax/rdi for its own purposes
    mov     rsi, s_mov_rax_rbx
    mov     rdx, s_mov_rax_rbx_len
    call    emit_str
    call    emit_nl
    mov     rdi, AST_TY_POINTER
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r12
    jmp     .exit

.binary:
    ; Every operand gen_rvalue can ever hand back is already guaranteed
    ; scalar/pointer by construction: .load_via_lvalue/.deref self-guard
    ; via is_scalar_loadable_type, INT/BOOL/NULL/neg/lnot/addr are always
    ; scalar/pointer by their own rules, and .call (below) rejects a
    ; composite-returning callee before ever returning here. So BINARY
    ; needs no separate guard of its own.
    mov     rax, [rbx + AST_A_OFF]      ; op
    cmp     rax, TOK_ANDAND
    je      .land
    cmp     rax, TOK_OROR
    je      .lor
    mov     rdi, [rbx + AST_B_OFF]      ; left
    call    gen_rvalue
    mov     r12, rax                    ; operand type (both sides equal)
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    call    emit_str
    call    emit_nl
    mov     rdi, [rbx + AST_C_OFF]      ; right
    call    gen_rvalue
    mov     rsi, s_mov_rcx_rax
    mov     rdx, s_mov_rcx_rax_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_pop_rax
    mov     rdx, s_pop_rax_len
    call    emit_str
    call    emit_nl
    mov     r13, r12                    ; protect operand type
    mov     rax, [rbx + AST_A_OFF]      ; op, re-derive
    call    gen_binary_combine          ; in rax=op, r13=operand type
    jmp     .exit

.land:
    call    next_label_suffix
    mov     r12, rax                    ; unique suffix for this occurrence
    mov     rdi, [rbx + AST_B_OFF]      ; a
    call    gen_rvalue
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_je_dotL
    mov     rdx, s_je_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_false
    mov     rdx, s_suf_false_len
    call    emit_label_ref
    call    emit_nl
    mov     rdi, [rbx + AST_C_OFF]      ; b
    call    gen_rvalue
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_ref
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_false
    mov     rdx, s_suf_false_len
    call    emit_label_def
    mov     rsi, s_mov_rax_0
    mov     rdx, s_mov_rax_0_len
    call    emit_str
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    call    get_bool_type
    jmp     .exit

.lor:
    call    next_label_suffix
    mov     r12, rax
    mov     rdi, [rbx + AST_B_OFF]      ; a
    call    gen_rvalue
    mov     rsi, s_cmp_rax_0
    mov     rdx, s_cmp_rax_0_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_jne_dotL
    mov     rdx, s_jne_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_true
    mov     rdx, s_suf_true_len
    call    emit_label_ref
    call    emit_nl
    mov     rdi, [rbx + AST_C_OFF]      ; b
    call    gen_rvalue
    mov     rsi, s_jmp_dotL
    mov     rdx, s_jmp_dotL_len
    call    emit_str
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_ref
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_true
    mov     rdx, s_suf_true_len
    call    emit_label_def
    mov     rsi, s_mov_rax_1
    mov     rdx, s_mov_rax_1_len
    call    emit_str
    call    emit_nl
    mov     rax, r12
    mov     rsi, s_suf_end
    mov     rdx, s_suf_end_len
    call    emit_label_def
    call    get_bool_type
    jmp     .exit

.call:
    mov     rax, [rbx + AST_A_OFF]      ; callee IDENT node
    mov     r12, [rax + AST_A_OFF]      ; callee name_offset
    mov     r13, [rax + AST_B_OFF]      ; callee name_len
    mov     rdi, r12
    mov     rsi, r13
    call    lookup_callable
    mov     r14, rax                    ; callable_table entry
    cmp     qword [r14 + CTE_IS_EXTERN], 0
    jne     .call_extern
    mov     rdi, rbx                    ; AST_EX_CALL node
    mov     rsi, r14                    ; callable_table entry
    call    gen_user_call
    jmp     .exit
.call_extern:
    mov     rdi, rbx                    ; AST_EX_CALL node
    mov     rsi, r14                    ; callable_table entry
    call    gen_extern_call
    jmp     .exit

.exit:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_binary_combine: internal. in rax = TOK_* binary op (arithmetic/
; bitwise/shift/div-mod/comparison -- NOT &&/||, handled separately by
; gen_rvalue's .land/.lor), r13 = operand type node ptr (both operands
; already type_equal-checked by the semantic checker). Assumes left is in
; rax, right is in rcx (gen_rvalue's .binary staging, ld. above). Emits
; the combine instruction(s), leaving the result in the emitted program's
; rax. out: rax (this routine's own return value) = the result's type
; node ptr -- r13 itself for arithmetic/bitwise/shift/div/mod, a fresh
; get_bool_type for comparisons.
; ===========================================================================
gen_binary_combine:
    cmp     rax, TOK_PLUS
    je      .add
    cmp     rax, TOK_MINUS
    je      .sub
    cmp     rax, TOK_STAR
    je      .mul
    cmp     rax, TOK_AMP
    je      .band
    cmp     rax, TOK_PIPE
    je      .bor
    cmp     rax, TOK_CARET
    je      .bxor
    cmp     rax, TOK_SHL
    je      .shl
    cmp     rax, TOK_SHR
    je      .shr
    cmp     rax, TOK_SLASH
    je      .sdiv
    cmp     rax, TOK_PERCENT
    je      .smod
    cmp     rax, TOK_EQ
    je      .eq
    cmp     rax, TOK_NE
    je      .ne
    cmp     rax, TOK_LT
    je      .lt
    cmp     rax, TOK_GT
    je      .gt
    cmp     rax, TOK_LE
    je      .le
    cmp     rax, TOK_GE
    je      .ge
    mov     rax, r13                    ; unreachable per grammar, defensive
    ret

.add:
    mov     rsi, s_add_rax_rcx
    mov     rdx, s_add_rax_rcx_len
    jmp     .arith_emit
.sub:
    mov     rsi, s_sub_rax_rcx
    mov     rdx, s_sub_rax_rcx_len
    jmp     .arith_emit
.mul:
    mov     rsi, s_imul_rax_rcx
    mov     rdx, s_imul_rax_rcx_len
    jmp     .arith_emit
.band:
    mov     rsi, s_and_rax_rcx
    mov     rdx, s_and_rax_rcx_len
    jmp     .arith_emit
.bor:
    mov     rsi, s_or_rax_rcx
    mov     rdx, s_or_rax_rcx_len
    jmp     .arith_emit
.bxor:
    mov     rsi, s_xor_rax_rcx
    mov     rdx, s_xor_rax_rcx_len
.arith_emit:
    call    emit_str
    call    emit_nl
    mov     rax, r13
    ret

.shl:
    mov     rsi, s_shl_rax_cl
    mov     rdx, s_shl_rax_cl_len
    call    emit_str
    call    emit_nl
    mov     rax, r13
    ret
.shr:
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .shr_u
    mov     rsi, s_sar_rax_cl
    mov     rdx, s_sar_rax_cl_len
    jmp     .shr_emit
.shr_u:
    mov     rsi, s_shr_rax_cl
    mov     rdx, s_shr_rax_cl_len
.shr_emit:
    call    emit_str
    call    emit_nl
    mov     rax, r13
    ret

.sdiv:
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .sdiv_u
    mov     rsi, s_cqo
    mov     rdx, s_cqo_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_idiv_rcx
    mov     rdx, s_idiv_rcx_len
    call    emit_str
    call    emit_nl
    jmp     .sdiv_done
.sdiv_u:
    mov     rsi, s_xor_rdx_rdx
    mov     rdx, s_xor_rdx_rdx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_div_rcx
    mov     rdx, s_div_rcx_len
    call    emit_str
    call    emit_nl
.sdiv_done:
    mov     rax, r13
    ret

.smod:
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .smod_u
    mov     rsi, s_cqo
    mov     rdx, s_cqo_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_idiv_rcx
    mov     rdx, s_idiv_rcx_len
    call    emit_str
    call    emit_nl
    jmp     .smod_move
.smod_u:
    mov     rsi, s_xor_rdx_rdx
    mov     rdx, s_xor_rdx_rdx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_div_rcx
    mov     rdx, s_div_rcx_len
    call    emit_str
    call    emit_nl
.smod_move:
    mov     rsi, s_mov_rax_rdx
    mov     rdx, s_mov_rax_rdx_len
    call    emit_str
    call    emit_nl
    mov     rax, r13
    ret

.eq:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_sete_al
    mov     rdx, s_sete_al_len
    jmp     .cmp_finish
.ne:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_setne_al
    mov     rdx, s_setne_al_len
    jmp     .cmp_finish
.lt:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .lt_u
    mov     rsi, s_setl_al
    mov     rdx, s_setl_al_len
    jmp     .cmp_finish
.lt_u:
    mov     rsi, s_setb_al
    mov     rdx, s_setb_al_len
    jmp     .cmp_finish
.gt:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .gt_u
    mov     rsi, s_setg_al
    mov     rdx, s_setg_al_len
    jmp     .cmp_finish
.gt_u:
    mov     rsi, s_seta_al
    mov     rdx, s_seta_al_len
    jmp     .cmp_finish
.le:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .le_u
    mov     rsi, s_setle_al
    mov     rdx, s_setle_al_len
    jmp     .cmp_finish
.le_u:
    mov     rsi, s_setbe_al
    mov     rdx, s_setbe_al_len
    jmp     .cmp_finish
.ge:
    mov     rsi, s_cmp_rax_rcx
    mov     rdx, s_cmp_rax_rcx_len
    call    emit_str
    call    emit_nl
    push    r13
    mov     rdi, r13
    call    is_signed_type
    pop     r13
    cmp     rax, 0
    je      .ge_u
    mov     rsi, s_setge_al
    mov     rdx, s_setge_al_len
    jmp     .cmp_finish
.ge_u:
    mov     rsi, s_setae_al
    mov     rdx, s_setae_al_len
.cmp_finish:
    call    emit_str
    call    emit_nl
    mov     rsi, s_movzx_rax_al
    mov     rdx, s_movzx_rax_al_len
    call    emit_str
    call    emit_nl
    call    get_bool_type
    ret

; ===========================================================================
; syscall_number_for: internal. in rdi = name_offset, rsi = name_len.
; out: rax = the fixed Linux x86_64 syscall number for one of the 4
; whitelisted extern names, cross-checked against runtime.asm's own
; hardcoded numbers for its I/O. Never called on a name that isn't one of
; these four -- check_extern_whitelist already rejected everything else
; before codegen ever runs.
; ===========================================================================
syscall_number_for:
    push    rbx
    push    r12
    mov     rbx, rdi                    ; name_offset
    mov     r12, rsi                    ; name_len
    cmp     r12, 8
    jne     .not_read
    mov     rdi, [parser_src_buf]
    add     rdi, rbx
    mov     rsi, str_sys_read
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .read
.not_read:
    cmp     r12, 9
    jne     .not_write
    mov     rdi, [parser_src_buf]
    add     rdi, rbx
    mov     rsi, str_sys_write
    mov     rdx, 9
    call    bytes_equal
    cmp     rax, 1
    je      .write
.not_write:
    cmp     r12, 8
    jne     .not_mmap
    mov     rdi, [parser_src_buf]
    add     rdi, rbx
    mov     rsi, str_sys_mmap
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .mmap
.not_mmap:
    cmp     r12, 8
    jne     .not_exit
    mov     rdi, [parser_src_buf]
    add     rdi, rbx
    mov     rsi, str_sys_exit
    mov     rdx, 8
    call    bytes_equal
    cmp     rax, 1
    je      .sys_exit
.not_exit:
    mov     rsi, msg_unknown_extern
    mov     rdx, msg_unknown_extern_len
    call    codegen_fail
.read:
    mov     rax, 0
    jmp     .done
.write:
    mov     rax, 1
    jmp     .done
.mmap:
    mov     rax, 9
    jmp     .done
.sys_exit:
    mov     rax, 60
    jmp     .done
.done:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_extern_call: internal. in rdi = AST_EX_CALL node, rsi = its resolved
; callable_table entry (is_extern = 1). out: rax = declared return type
; (0 = void). Emits: each arg evaluated right to left and pushed (ld.
; "Calling convention"); popped in order into rdi/rsi/rdx/r10(via rcx)/r8/
; r9 (first-pushed = arg1 = popped first, since it was evaluated and
; pushed LAST); the fixed syscall number; `syscall`. Result already lands
; in rax -- the emitted syscall's own return register, same as this
; convention's rax-for-scalar-return rule, no extra move needed.
; ===========================================================================
gen_extern_call:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; AST_EX_CALL node
    mov     r12, rsi                    ; callable_table entry
    mov     r13, [rbx + AST_B_OFF]      ; args ptr
    mov     r14, [rbx + AST_C_OFF]      ; arg_count
    mov     r15, r14                    ; loop index, counts arg_count..1,
                                         ; evaluating/pushing right to left
.push_loop:
    cmp     r15, 0
    je      .push_done
    dec     r15
    mov     rdi, [r13 + r15*8]          ; args[r15]
    push    r15                         ; gen_rvalue doesn't preserve r15
    call    gen_rvalue                  ; emits code computing the value
                                         ; into the emitted program's rax
    pop     r15
    mov     rsi, s_push_rax             ; emit the matching (target-side)
    mov     rdx, s_push_rax_len         ; "push rax" text
    call    emit_str
    call    emit_nl
    jmp     .push_loop
.push_done:
    ; pop into the fixed syscall registers, in order rdi/rsi/rdx/rcx(->r10)
    ; /r8/r9 -- only as many as this call actually has (arg_count <= 6,
    ; guaranteed by the whitelist). First-pushed (argN) pops last; arg1,
    ; pushed last, pops first into rdi -- correct by construction.
    cmp     r14, 1
    jl      .args_popped
    mov     rsi, s_pop_rdi
    mov     rdx, s_pop_rdi_len
    call    emit_str
    call    emit_nl
    cmp     r14, 2
    jl      .args_popped
    mov     rsi, s_pop_rsi
    mov     rdx, s_pop_rsi_len
    call    emit_str
    call    emit_nl
    cmp     r14, 3
    jl      .args_popped
    mov     rsi, s_pop_rdx
    mov     rdx, s_pop_rdx_len
    call    emit_str
    call    emit_nl
    cmp     r14, 4
    jl      .args_popped
    mov     rsi, s_pop_rcx
    mov     rdx, s_pop_rcx_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_mov_r10_rcx          ; syscall clobbers rcx/r11 itself,
    mov     rdx, s_mov_r10_rcx_len      ; so the 4th arg travels via r10
    call    emit_str
    call    emit_nl
    cmp     r14, 5
    jl      .args_popped
    mov     rsi, s_pop_r8
    mov     rdx, s_pop_r8_len
    call    emit_str
    call    emit_nl
    cmp     r14, 6
    jl      .args_popped
    mov     rsi, s_pop_r9
    mov     rdx, s_pop_r9_len
    call    emit_str
    call    emit_nl
.args_popped:
    mov     rax, [r12 + CTE_SIG_PTR]
    mov     rdi, [rax + AST_A_OFF]      ; signature's name_offset
    mov     rsi, [rax + AST_B_OFF]      ; name_len
    call    syscall_number_for
    mov     r13, rax                    ; protect across emit_str
    mov     rsi, s_mov_rax_
    mov     rdx, s_mov_rax__len
    call    emit_str
    mov     rax, r13
    call    emit_dec
    call    emit_nl
    mov     rsi, s_syscall
    mov     rdx, s_syscall_len
    call    emit_str
    call    emit_nl
    mov     rax, [r12 + CTE_RET_TYPE]   ; 0 = void
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; gen_user_call: internal. in rdi = AST_EX_CALL node, rsi = its resolved
; callable_table entry (is_extern = 0). out: rax = declared return type
; (0 = void). Implements the custom calling convention Phase 1's spec
; already fully decided: args evaluated right to left and pushed (one
; padding push first if N is odd, so arg1 still lands exactly at [rsp]
; after all N real args -- ld. "Calling convention"); mov rdi, rsp; mov
; rsi, N; call pf_<name>; add rsp, <N*8 padded to 16>. Every argument
; gen_rvalue hands back is already guaranteed scalar/pointer (ld.
; gen_rvalue's own self-guarding, noted at .binary above) -- no separate
; per-argument guard needed here, only the callee's own return type.
; ===========================================================================
gen_user_call:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; AST_EX_CALL node
    mov     r12, rsi                    ; callable_table entry

    mov     rax, [r12 + CTE_RET_TYPE]   ; 0 = void
    cmp     rax, 0
    je      .ret_ok
    mov     rdi, rax
    call    is_scalar_loadable_type
    cmp     rax, 0
    jne     .ret_ok
    mov     rsi, msg_composite_call_boundary
    mov     rdx, msg_composite_call_boundary_len
    call    codegen_fail
.ret_ok:
    mov     r13, [rbx + AST_B_OFF]      ; args ptr
    mov     r14, [rbx + AST_C_OFF]      ; arg_count

    mov     rax, r14
    and     rax, 1
    cmp     rax, 0
    je      .no_pad
    mov     rsi, s_push_rax             ; dummy padding, pushed FIRST so
    mov     rdx, s_push_rax_len         ; it ends up farthest from rsp --
    call    emit_str                    ; arg1 (pushed last) still lands
    call    emit_nl                     ; exactly at [rsp]
.no_pad:
    mov     r15, r14                    ; loop index, counts arg_count..1
.push_loop:
    cmp     r15, 0
    je      .push_done
    dec     r15
    mov     rdi, [r13 + r15*8]
    push    r15
    call    gen_rvalue                  ; self-guarded; emits value into
                                         ; the target program's rax
    pop     r15
    mov     rsi, s_push_rax
    mov     rdx, s_push_rax_len
    call    emit_str
    call    emit_nl
    jmp     .push_loop
.push_done:
    mov     rsi, s_mov_rdi_rsp
    mov     rdx, s_mov_rdi_rsp_len
    call    emit_str
    call    emit_nl
    mov     rsi, s_mov_rsi_
    mov     rdx, s_mov_rsi__len
    call    emit_str
    mov     rax, r14
    call    emit_dec
    call    emit_nl

    mov     rsi, s_call_pf_
    mov     rdx, s_call_pf__len
    call    emit_str
    mov     rax, [rbx + AST_A_OFF]      ; callee IDENT node
    mov     rsi, [parser_src_buf]
    add     rsi, [rax + AST_A_OFF]
    mov     rdx, [rax + AST_B_OFF]
    call    emit_str
    call    emit_nl

    mov     rax, r14
    imul    rax, rax, 8
    add     rax, 15
    and     rax, ~15                    ; N*8 padded up to a multiple of
                                         ; 16 -- correctly (N+1)*8 when N
                                         ; is odd, matching the padding
                                         ; push above
    mov     r13, rax                    ; padded cleanup size -- rcx is
                                         ; NOT safe across emit_str (its
                                         ; own copy-loop counter, always
                                         ; left at 0)
    mov     rsi, s_add_rsp_
    mov     rdx, s_add_rsp__len
    call    emit_str
    mov     rax, r13
    call    emit_dec
    call    emit_nl

    mov     rax, [r12 + CTE_RET_TYPE]   ; 0 = void
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
