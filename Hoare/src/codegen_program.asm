; Postulate Stage 0 -- code generator: per-function stack layout, function
; prologue/epilogue, and top-level (AST_PROGRAM/_start) emission.
; See docs/postulate_stage0_codegen_spec.md.
;
; Phase 2 scope enforcement lives here: any number of AST_FUNCTION decls,
; each getting its own pf_<name> label, exactly one of which must be
; named "main" (the _start entry point, which calls pf_main with no
; arguments -- so main itself must take zero params). A function's
; return type, and every one of its PARAMS specifically (params cross
; the function-call boundary, unlike plain locals/decls, which may be
; any type -- see gen_function/gen_decl respectively), must be
; scalar-loadable -- passing/returning a struct/array *by value* through
; a call is a separate, not-yet-designed future phase. AST_STRUCT_DECL
; contributes nothing at this level (purely a layout fact, consumed via
; type_size/field_offset elsewhere). AST_EXTERN_DECL likewise -- it only
; ever affects AST_EX_CALL codegen (codegen_expr.asm's gen_extern_call).
;
; Register-safety convention (applies to every routine in this file): no
; callee, including the trivial ones (emit_str/emit_dec/emit_nl), is
; ever trusted to leave any register untouched across a call. Whenever a
; value must survive a call, the function that needs it pushes it
; immediately before that one call and pops it immediately after -- never
; spanning more than one call per push/pop pair. Consequently no routine
; here has a prologue/epilogue save of its caller's rbx/r12-r15 either:
; since every caller now protects its own values around each call it
; makes, a callee no longer needs to preserve its caller's incoming
; register contents on its own initiative.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern bytes_equal
extern build_local_table
extern local_table
extern local_count
extern type_size
extern is_signed_type
extern is_scalar_loadable_type
extern gen_func_block
extern codegen_fail
extern emit_str
extern emit_dec
extern emit_nl
extern emit_rep_movsb_copy

global local_stack_offset
global compute_local_offsets
global gen_function
global gen_program
global cur_func_return_type
global cur_func_out_ptr_offset

section .bss
local_offsets: resq MAX_LIST_ARITY
; set once by gen_function, right before it calls gen_func_block; read by
; codegen_stmt.asm's gen_stmt .return_stmt case (see gen_function header)
cur_func_return_type: resq 1
cur_func_out_ptr_offset: resq 1

section .data
str_main: db "main"

msg_no_main: db "no 'main' function found -- exactly one function must be named 'main'"
msg_no_main_len equ $ - msg_no_main
msg_main_has_params: db "the entry point 'main' must have no parameters"
msg_main_has_params_len equ $ - msg_main_has_params

s_pf_prefix: db "pf_"
s_pf_prefix_len equ $ - s_pf_prefix
s_colon_nl: db ":", 10
s_colon_nl_len equ $ - s_colon_nl
s_push_rbp: db "    push    rbp", 10
s_push_rbp_len equ $ - s_push_rbp
s_mov_rbp_rsp: db "    mov     rbp, rsp", 10
s_mov_rbp_rsp_len equ $ - s_mov_rbp_rsp
s_sub_rsp_: db "    sub     rsp, "
s_sub_rsp__len equ $ - s_sub_rsp_
s_epilogue_label: db ".epilogue:", 10
s_epilogue_label_len equ $ - s_epilogue_label
s_mov_rsp_rbp: db "    mov     rsp, rbp", 10
s_mov_rsp_rbp_len equ $ - s_mov_rsp_rbp
s_pop_rbp: db "    pop     rbp", 10
s_pop_rbp_len equ $ - s_pop_rbp
s_ret: db "    ret", 10
s_ret_len equ $ - s_ret
s_nl: db 10

s_header: db "BITS 64", 10, "section .text", 10, "global _start", 10, 10, "_start:", 10, "    call    pf_main", 10
s_header_len equ $ - s_header
s_mov_rdi_rax: db "    mov     rdi, rax", 10
s_mov_rdi_rax_len equ $ - s_mov_rdi_rax
s_mov_rdi_0: db "    mov     rdi, 0", 10
s_mov_rdi_0_len equ $ - s_mov_rdi_0
s_exit_tail: db "    mov     rax, 60", 10, "    syscall", 10, 10
s_exit_tail_len equ $ - s_exit_tail

s_movsx_rax_byte_from: db "    movsx   rax, byte [rdi + "
s_movsx_rax_byte_from_len equ $ - s_movsx_rax_byte_from
s_movzx_rax_byte_from: db "    movzx   rax, byte [rdi + "
s_movzx_rax_byte_from_len equ $ - s_movzx_rax_byte_from
s_movsx_rax_word_from: db "    movsx   rax, word [rdi + "
s_movsx_rax_word_from_len equ $ - s_movsx_rax_word_from
s_movzx_rax_word_from: db "    movzx   rax, word [rdi + "
s_movzx_rax_word_from_len equ $ - s_movzx_rax_word_from
s_movsxd_rax_dword_from: db "    movsxd  rax, dword [rdi + "
s_movsxd_rax_dword_from_len equ $ - s_movsxd_rax_dword_from
s_mov_eax_dword_from: db "    mov     eax, dword [rdi + "
s_mov_eax_dword_from_len equ $ - s_mov_eax_dword_from
s_mov_rax_qword_from: db "    mov     rax, qword [rdi + "
s_mov_rax_qword_from_len equ $ - s_mov_rax_qword_from
s_close_bracket_nl: db "]", 10
s_close_bracket_nl_len equ $ - s_close_bracket_nl

s_mov_byte_rbp_minus: db "    mov     byte [rbp - "
s_mov_byte_rbp_minus_len equ $ - s_mov_byte_rbp_minus
s_mov_word_rbp_minus: db "    mov     word [rbp - "
s_mov_word_rbp_minus_len equ $ - s_mov_word_rbp_minus
s_mov_dword_rbp_minus: db "    mov     dword [rbp - "
s_mov_dword_rbp_minus_len equ $ - s_mov_dword_rbp_minus
s_mov_qword_rbp_minus: db "    mov     qword [rbp - "
s_mov_qword_rbp_minus_len equ $ - s_mov_qword_rbp_minus
s_comma_al_nl: db "], al", 10
s_comma_al_nl_len equ $ - s_comma_al_nl
s_comma_ax_nl: db "], ax", 10
s_comma_ax_nl_len equ $ - s_comma_ax_nl
s_comma_eax_nl: db "], eax", 10
s_comma_eax_nl_len equ $ - s_comma_eax_nl
s_comma_rax_nl: db "], rax", 10
s_comma_rax_nl_len equ $ - s_comma_rax_nl
s_comma_rdx_nl: db "], rdx", 10
s_comma_rdx_nl_len equ $ - s_comma_rdx_nl

s_push_rdi: db "    push    rdi", 10
s_push_rdi_len equ $ - s_push_rdi
s_pop_rdi: db "    pop     rdi", 10
s_pop_rdi_len equ $ - s_pop_rdi
s_mov_rsi_rdi_plus: db "    mov     rsi, [rdi + "
s_mov_rsi_rdi_plus_len equ $ - s_mov_rsi_rdi_plus
s_lea_rdi_rbp_minus: db "    lea     rdi, [rbp - "
s_lea_rdi_rbp_minus_len equ $ - s_lea_rdi_rbp_minus

section .text

; ===========================================================================
; local_stack_offset: in rdi = local_table entry ptr. out: rax = its
; stack offset (positive byte count below rbp -- the local's address is
; [rbp - offset]). Index derived from the entry's own position in
; local_table (identical indexing to local_offsets, populated by
; compute_local_offsets right after each build_local_table call).
; ===========================================================================
local_stack_offset:
    mov     rax, rdi
    sub     rax, local_table
    xor     rdx, rdx
    mov     rcx, LOCAL_ENTRY_SIZE
    div     rcx                          ; rax = index
    mov     rax, [local_offsets + rax*8]
    ret

; ===========================================================================
; compute_local_offsets: populates local_offsets[0 .. local_count) from
; the just-built local_table -- each local gets a tightly packed slot
; sized per its own declared type, accumulated from rbp downward (locals
; only, no alignment concern beyond the final round-up below -- scalar
; sizes are all powers of two <= 8, so a running byte-sum never misaligns
; any individual load/store). out: rax = total locals_size, rounded up to
; a multiple of 16 (see "Stack frame layout"'s alignment invariant).
; ===========================================================================
compute_local_offsets:
    mov     rbx, [local_count]
    xor     r12, r12                     ; running total
    xor     rcx, rcx
.loop:
    cmp     rcx, rbx
    jae     .round
    push    rcx
    mov     rax, rcx
    imul    rax, rax, LOCAL_ENTRY_SIZE
    lea     rax, [local_table + rax]
    mov     rdi, [rax + LTE_TYPE_PTR]
    push    rbx
    push    r12
    call    type_size
    pop     r12
    pop     rbx
    add     r12, rax
    mov     rax, r12
    pop     rcx
    mov     [local_offsets + rcx*8], rax
    inc     rcx
    jmp     .loop
.round:
    mov     rax, r12
    add     rax, 15
    and     rax, ~15
    ret

; ===========================================================================
; emit_param_copy: internal. in rdi = param's declared type, rsi = its
; byte offset in the incoming arg block ((i-1)*8 relabeled 0-based: i*8
; for the i-th param, 0-based), rdx = its own local stack offset.
; Scalar/pointer: emits a sized load from "[rdi + <arg offset>]" into
; rax, then a sized store into "[rbp - <local offset>]" -- the
; prologue's per-param copy step (see "Stack frame layout"). Composite
; (Phase 3): the incoming slot holds a POINTER instead of a value (see
; gen_user_call's own header) -- copies `size` bytes FROM [that pointer]
; into this function's own local slot via rep movsb, giving this
; function a true, independent-by-value copy (mirrors the already-built
; p2 := p1; copy path). Either way, target rdi (the incoming-args-base
; pointer, needed by every OTHER param's own copy in gen_function's
; loop) is left exactly as it was found -- the composite branch
; explicitly saves/restores it around repurposing it as rep movsb's
; destination register.
; ===========================================================================
emit_param_copy:
    mov     r12, rsi                     ; arg byte offset
    mov     r13, rdx                     ; local stack offset
    push    rdi
    push    r12
    push    r13
    call    is_scalar_loadable_type
    pop     r13
    pop     r12
    pop     rdi
    cmp     rax, 0
    je      .composite

    push    rdi
    push    r12
    push    r13
    call    type_size
    pop     r13
    pop     r12
    pop     rdi
    mov     rbx, rax                     ; size
    push    rbx
    push    rdi
    push    r12
    push    r13
    call    is_signed_type
    pop     r13
    pop     r12
    pop     rdi
    pop     rbx
    mov     rdx, rax                     ; signed?
    cmp     rbx, 1
    je      .b1
    cmp     rbx, 2
    je      .b2
    cmp     rbx, 4
    je      .b4
    jmp     .b8
.b1:
    cmp     rdx, 0
    je      .b1u
    mov     rsi, s_movsx_rax_byte_from
    mov     rdx, s_movsx_rax_byte_from_len
    jmp     .load_emit
.b1u:
    mov     rsi, s_movzx_rax_byte_from
    mov     rdx, s_movzx_rax_byte_from_len
    jmp     .load_emit
.b2:
    cmp     rdx, 0
    je      .b2u
    mov     rsi, s_movsx_rax_word_from
    mov     rdx, s_movsx_rax_word_from_len
    jmp     .load_emit
.b2u:
    mov     rsi, s_movzx_rax_word_from
    mov     rdx, s_movzx_rax_word_from_len
    jmp     .load_emit
.b4:
    cmp     rdx, 0
    je      .b4u
    mov     rsi, s_movsxd_rax_dword_from
    mov     rdx, s_movsxd_rax_dword_from_len
    jmp     .load_emit
.b4u:
    mov     rsi, s_mov_eax_dword_from
    mov     rdx, s_mov_eax_dword_from_len
    jmp     .load_emit
.b8:
    mov     rsi, s_mov_rax_qword_from
    mov     rdx, s_mov_rax_qword_from_len
.load_emit:
    push    rbx
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r12                     ; r12's last use
    push    rbx
    push    r13
    call    emit_dec
    pop     r13
    pop     rbx
    mov     rsi, s_close_bracket_nl
    mov     rdx, s_close_bracket_nl_len
    push    rbx
    push    r13
    call    emit_str
    pop     r13
    pop     rbx

    cmp     rbx, 1
    je      .s1
    cmp     rbx, 2
    je      .s2
    cmp     rbx, 4
    je      .s4
    mov     rsi, s_mov_qword_rbp_minus
    mov     rdx, s_mov_qword_rbp_minus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13                     ; r13's last use
    call    emit_dec
    mov     rsi, s_comma_rax_nl
    mov     rdx, s_comma_rax_nl_len
    call    emit_str
    jmp     .done
.s1:
    mov     rsi, s_mov_byte_rbp_minus
    mov     rdx, s_mov_byte_rbp_minus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_comma_al_nl
    mov     rdx, s_comma_al_nl_len
    call    emit_str
    jmp     .done
.s2:
    mov     rsi, s_mov_word_rbp_minus
    mov     rdx, s_mov_word_rbp_minus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_comma_ax_nl
    mov     rdx, s_comma_ax_nl_len
    call    emit_str
    jmp     .done
.s4:
    mov     rsi, s_mov_dword_rbp_minus
    mov     rdx, s_mov_dword_rbp_minus_len
    push    r13
    call    emit_str
    pop     r13
    mov     rax, r13
    call    emit_dec
    mov     rsi, s_comma_eax_nl
    mov     rdx, s_comma_eax_nl_len
    call    emit_str
.done:
    ret

.composite:
    push    rdi                          ; declared type -- protect
    push    r12                          ; across type_size
    push    r13
    call    type_size
    pop     r13
    pop     r12
    pop     rdi
    mov     rbx, rax                     ; size

    mov     rsi, s_push_rdi
    mov     rdx, s_push_rdi_len
    push    rbx
    push    r12
    push    r13
    call    emit_str                     ; protect the incoming-args-
    pop     r13                          ; base pointer -- we're about
    pop     r12                          ; to repurpose target rdi below
    pop     rbx

    mov     rsi, s_mov_rsi_rdi_plus
    mov     rdx, s_mov_rsi_rdi_plus_len
    push    rbx
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r12
    push    rbx
    push    r13
    call    emit_dec
    pop     r13
    pop     rbx
    mov     rsi, s_close_bracket_nl
    mov     rdx, s_close_bracket_nl_len
    push    rbx
    push    r13
    call    emit_str                     ; target rsi = source pointer
    pop     r13                          ; (the value this argument's
    pop     rbx                          ; slot actually holds)

    mov     rsi, s_lea_rdi_rbp_minus
    mov     rdx, s_lea_rdi_rbp_minus_len
    push    rbx
    push    r13
    call    emit_str
    pop     r13
    pop     rbx
    mov     rax, r13
    push    rbx
    call    emit_dec
    pop     rbx
    mov     rsi, s_close_bracket_nl
    mov     rdx, s_close_bracket_nl_len
    push    rbx
    call    emit_str                     ; target rdi = this local's own
    pop     rbx                          ; slot (clobbers the incoming-
                                          ; args-base, saved above)

    mov     rdi, rbx
    call    emit_rep_movsb_copy

    mov     rsi, s_pop_rdi
    mov     rdx, s_pop_rdi_len
    call    emit_str                     ; restore the incoming-args-
    ret                                  ; base pointer for the next param

; ===========================================================================
; gen_function: in rdi = AST_FUNCTION ptr. Rebuilds this function's local
; table + stack offsets, then emits its pf_<name> label, prologue (incl.
; per-param copy), body, and epilogue. Phase 3: both a composite return
; type and composite param types are now accepted -- a composite param's
; incoming slot holds a POINTER (see emit_param_copy's composite branch,
; which copies FROM it, giving this function its own independent-by-
; value copy); a composite return type additionally reserves one hidden,
; always-8-byte frame slot (immediately below the user-visible locals,
; sized into the same prologue "sub rsp") holding the incoming output
; pointer (target rdx at function entry, per the calling convention),
; saved there right after the prologue -- before ANYTHING else in this
; function's body gets a chance to clobber rdx -- and threaded down into
; gen_func_block/gen_block/gen_stmt (rsi = declared return type, rdx =
; this hidden slot's offset, 0/0 for void or a scalar return -- see
; codegen_stmt.asm's .return_stmt) so a composite RETURN statement knows
; where to write its result.
; ===========================================================================
gen_function:
    mov     rbx, rdi                     ; AST_FUNCTION node
    mov     r12, [rbx + AST_A_OFF]       ; signature ptr
    mov     r8, [rbx + AST_B_OFF]        ; declared return type, 0 = void

    mov     rdi, r12
    mov     rsi, [rbx + AST_C_OFF]       ; body (func_block)
    push    rbx
    push    r12
    push    r8
    call    build_local_table
    pop     r8
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r8
    call    compute_local_offsets
    pop     r8
    pop     r12
    pop     rbx
    mov     r13, rax                     ; locals_size (already rounded
                                          ; to 16)

    xor     r9, r9                       ; hidden_slot_offset, 0 = none
    cmp     r8, 0
    je      .ret_scalar_or_void
    mov     rdi, r8
    push    rbx
    push    r12
    push    r13
    push    r8
    call    is_scalar_loadable_type
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    cmp     rax, 0
    jne     .ret_scalar_or_void
    ; composite return: one extra hidden 8-byte slot, right after the
    ; user-visible locals; total prologue reservation re-rounded to 16
    mov     r9, r13
    add     r9, 8                        ; hidden_slot_offset -- slot is
                                          ; at [rbp - r9]
    mov     rax, r9
    add     rax, 15
    and     rax, ~15
    mov     r13, rax                     ; new prologue reservation size
.ret_scalar_or_void:

    mov     rsi, s_pf_prefix
    mov     rdx, s_pf_prefix_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, [r12 + AST_A_OFF]       ; name_offset
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [r12 + AST_B_OFF]       ; name_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_colon_nl
    mov     rdx, s_colon_nl_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_push_rbp
    mov     rdx, s_push_rbp_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_mov_rbp_rsp
    mov     rdx, s_mov_rbp_rsp_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    cmp     r13, 0
    je      .no_locals
    mov     rsi, s_sub_rsp_
    mov     rdx, s_sub_rsp__len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r13
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_dec
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_nl
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
.no_locals:

    cmp     r9, 0
    je      .no_out_ptr_save
    mov     rsi, s_mov_qword_rbp_minus
    mov     rdx, s_mov_qword_rbp_minus_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rax, r9
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_dec
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
    mov     rsi, s_comma_rdx_nl
    mov     rdx, s_comma_rdx_nl_len
    push    rbx
    push    r12
    push    r13
    push    r8
    push    r9
    call    emit_str                     ; incoming output pointer saved
                                          ; -- before anything else in
                                          ; this function's body can
                                          ; clobber target rdx
    pop     r9
    pop     r8
    pop     r13
    pop     r12
    pop     rbx
.no_out_ptr_save:

    ; per-param copy: local_table[0 .. param_count) are exactly the
    ; params, in order (build_local_table adds params before decls). r12
    ; (signature ptr) is read once more just below, then not again.
    mov     r14, [r12 + AST_C_OFF]       ; params ptr
    mov     r13, [r12 + AST_D_OFF]       ; param_count (locals_size no
                                          ; longer needed)
    xor     r15, r15                     ; index
.param_loop:
    cmp     r15, r13
    jae     .params_done
    mov     rax, r15
    imul    rax, rax, LOCAL_ENTRY_SIZE
    lea     rax, [local_table + rax]     ; this param's local_table entry
    mov     rdi, rax
    push    rbx
    push    r13
    push    r14
    push    r15
    push    r8
    push    r9
    call    local_stack_offset           ; -> rax = local stack offset
    pop     r9
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx
    mov     rcx, rax                     ; stash -- not held across any
                                          ; further call before its use
                                          ; just below

    mov     rax, [r14 + r15*8]
    mov     rdi, [rax + AST_C_OFF]       ; declared type
    mov     rsi, r15
    imul    rsi, rsi, 8                  ; arg byte offset = index*8
    mov     rdx, rcx                     ; local stack offset
    push    rbx
    push    r13
    push    r14
    push    r15
    push    r8
    push    r9
    call    emit_param_copy
    pop     r9
    pop     r8
    pop     r15
    pop     r14
    pop     r13
    pop     rbx

    inc     r15
    jmp     .param_loop
.params_done:
    ; gen_stmt's .return_stmt (codegen_stmt.asm) needs to know this
    ; function's declared return type and, if composite, where the
    ; hidden output-pointer slot is -- handed over via these two module-
    ; level globals (set here, once, before gen_func_block ever runs)
    ; rather than threaded as parameters through gen_func_block/gen_block
    ; /gen_stmt's own call chain: gen_function is never reentrant (a
    ; function body never triggers codegen of another function's body
    ; mid-flight, see gen_program), so there is exactly one live value
    ; at a time -- no risk of one function's return context leaking into
    ; another's.
    mov     [cur_func_return_type], r8
    mov     [cur_func_out_ptr_offset], r9
    mov     rdi, [rbx + AST_C_OFF]       ; body -- rbx's last use
    call    gen_func_block

    mov     rsi, s_epilogue_label
    mov     rdx, s_epilogue_label_len
    call    emit_str
    mov     rsi, s_mov_rsp_rbp
    mov     rdx, s_mov_rsp_rbp_len
    call    emit_str
    mov     rsi, s_pop_rbp
    mov     rdx, s_pop_rbp_len
    call    emit_str
    mov     rsi, s_ret
    mov     rdx, s_ret_len
    call    emit_str

    ret

; ===========================================================================
; gen_program: in rdi = AST_PROGRAM ptr. Finds the (exactly one) function
; named "main" (0-param, see file header), emits the _start entry point
; wired to call pf_main and sys_exit its result, then generates EVERY
; AST_FUNCTION decl (not just main) -- struct decls and extern decls
; contribute nothing at this level, silently skipped. Functions are
; generated in declaration order, but that's just a traversal choice:
; label references across functions resolve at NASM assembly time
; regardless of emission order, so mutual recursion needs no special
; handling here.
; ===========================================================================
gen_program:
    mov     rbx, rdi
    mov     r12, [rbx + AST_A_OFF]       ; decls ptr
    mov     r13, [rbx + AST_B_OFF]       ; decl_count -- rbx itself is
                                          ; never read again after this
                                          ; point, so it needs no further
                                          ; protection in this function
    xor     r14, r14                     ; main function node, 0 = not found
    xor     rcx, rcx
.scan_loop:
    cmp     rcx, r13
    jae     .scan_done
    mov     rax, [r12 + rcx*8]
    cmp     qword [rax + AST_KIND_OFF], AST_FUNCTION
    jne     .scan_next
    mov     rax, [rax + AST_A_OFF]       ; signature ptr
    mov     rdx, [rax + AST_B_OFF]       ; name_len
    cmp     rdx, 4
    jne     .scan_next
    push    rcx
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]       ; name text
    mov     rsi, str_main
    mov     rdx, 4
    push    r12
    push    r13
    call    bytes_equal
    pop     r13
    pop     r12
    pop     rcx
    cmp     rax, 1
    jne     .scan_next
    mov     r14, [r12 + rcx*8]           ; found main -- write-only across
                                          ; the call above, so r14 itself
                                          ; never needed protecting there
.scan_next:
    inc     rcx
    jmp     .scan_loop
.scan_done:
    cmp     r14, 0
    jne     .have_main
    mov     rsi, msg_no_main
    mov     rdx, msg_no_main_len
    call    codegen_fail
.have_main:
    mov     rax, [r14 + AST_A_OFF]       ; main's signature ptr
    cmp     qword [rax + AST_D_OFF], 0   ; param_count
    je      .main_params_ok
    mov     rsi, msg_main_has_params
    mov     rdx, msg_main_has_params_len
    call    codegen_fail
.main_params_ok:
    mov     rsi, s_header
    mov     rdx, s_header_len
    push    r12
    push    r13
    push    r14
    call    emit_str
    pop     r14
    pop     r13
    pop     r12
    mov     rax, [r14 + AST_B_OFF]       ; main's return type, 0 = void
    cmp     rax, 0
    jne     .nonvoid_main
    mov     rsi, s_mov_rdi_0
    mov     rdx, s_mov_rdi_0_len
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
    jmp     .exit_tail
.nonvoid_main:
    mov     rsi, s_mov_rdi_rax
    mov     rdx, s_mov_rdi_rax_len
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12
.exit_tail:
    mov     rsi, s_exit_tail
    mov     rdx, s_exit_tail_len
    push    r12
    push    r13
    call    emit_str
    pop     r13
    pop     r12

    xor     rcx, rcx
.gen_loop:
    cmp     rcx, r13
    jae     .gen_done
    mov     rax, [r12 + rcx*8]
    cmp     qword [rax + AST_KIND_OFF], AST_FUNCTION
    jne     .gen_next
    push    rcx
    mov     rdi, rax
    push    r12
    push    r13
    call    gen_function
    pop     r13
    pop     r12
    pop     rcx
.gen_next:
    inc     rcx
    jmp     .gen_loop
.gen_done:
    ret
