; Postulate Stage 0 -- semantic analyzer: symbol tables + diagnostics.
; See docs/postulate_stage0_semantics_spec.md.
;
; Two flat, MAX_LIST_ARITY-capped tables (no dynamic allocation, no scope
; nesting -- Stage 0 only allows `decl` at a func_block's own top, so
; there is exactly one flat local scope per function):
;   - global tables (struct_table, callable_table): built once per
;     AST_PROGRAM, before any function body is checked, so declaration
;     order and mutual/forward references just work.
;   - local table: rebuilt fresh before checking each function body, from
;     its params + its func_block's decls.
;
; Also hosts the semantic-error diagnostic helpers (sema_report_begin/
; sema_report_finish, err_append_span) shared by every sema_*.asm file --
; parallels parser_tokens.asm bundling report_parse_error alongside the
; token-lookahead machinery it's used from.

%include "config.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern resolve_type

global build_global_tables
global lookup_struct
global lookup_callable
global build_local_table
global lookup_local
global sema_report_begin
global sema_report_finish
global err_append_span
global quote_char
global bytes_equal

section .bss
struct_table:    resb MAX_LIST_ARITY * STRUCT_ENTRY_SIZE
struct_count:    resq 1
callable_table:  resb MAX_LIST_ARITY * CALLABLE_ENTRY_SIZE
callable_count:  resq 1
local_table:     resb MAX_LIST_ARITY * LOCAL_ENTRY_SIZE
local_count:     resq 1

section .data
quote_char: db "'"
msg_semantic_prefix:  db "semantic error: "
msg_semantic_prefix_len equ $ - msg_semantic_prefix
msg_at_line:          db " at line "
msg_at_line_len       equ $ - msg_at_line
msg_col:              db ", col "
msg_col_len           equ $ - msg_col
msg_byte_offset:      db " (byte offset "
msg_byte_offset_len   equ $ - msg_byte_offset
msg_close_paren_nl:   db ")", 10
msg_close_paren_nl_len equ $ - msg_close_paren_nl
msg_duplicate_top_level:  db "duplicate top-level name '"
msg_duplicate_top_level_len equ $ - msg_duplicate_top_level
msg_duplicate_local:      db "duplicate parameter/declaration name '"
msg_duplicate_local_len   equ $ - msg_duplicate_local
msg_too_many_structs:      db "too many struct declarations"
msg_too_many_structs_len   equ $ - msg_too_many_structs
msg_too_many_callables:     db "too many function/extern declarations"
msg_too_many_callables_len  equ $ - msg_too_many_callables
msg_too_many_locals:         db "too many parameters/declarations in one function"
msg_too_many_locals_len      equ $ - msg_too_many_locals

section .text

; ===========================================================================
; sema_report_begin: resets err_cursor, appends "semantic error: ". Call
; first, then build the message body via err_append_str/err_append_span,
; then finish with sema_report_finish.
; ===========================================================================
sema_report_begin:
    mov     qword [err_cursor], 0
    mov     rsi, msg_semantic_prefix
    mov     rdx, msg_semantic_prefix_len
    jmp     err_append_str

; ===========================================================================
; sema_report_finish: in rdi = source byte offset to report the position
; of. Appends " at line L, col C (byte offset O)\n", writes err_buf to
; stderr, exit(3). Never returns.
; ===========================================================================
sema_report_finish:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                 ; offset
    call    compute_line_col         ; rdi already = offset; out rax=line, rdx=col
    mov     r12, rax                 ; line
    mov     r13, rdx                 ; col

    mov     rsi, msg_at_line
    mov     rdx, msg_at_line_len
    call    err_append_str

    mov     rax, r12
    call    err_append_dec

    mov     rsi, msg_col
    mov     rdx, msg_col_len
    call    err_append_str

    mov     rax, r13
    call    err_append_dec

    mov     rsi, msg_byte_offset
    mov     rdx, msg_byte_offset_len
    call    err_append_str

    mov     rax, rbx
    call    err_append_dec

    mov     rsi, msg_close_paren_nl
    mov     rdx, msg_close_paren_nl_len
    call    err_append_str

    mov     rdi, 2
    mov     rsi, err_buf
    mov     rdx, [err_cursor]
    call    write_all

    mov     rax, 60
    mov     rdi, 3
    syscall

; ===========================================================================
; err_append_span: in rdi = source byte offset, rsi = length. Appends that
; source span (re-sliced from parser_src_buf) via err_append_str.
; ===========================================================================
err_append_span:
    mov     rdx, rsi
    mov     rsi, [parser_src_buf]
    add     rsi, rdi
    jmp     err_append_str

; ===========================================================================
; bytes_equal: in rdi = ptr1, rsi = ptr2, rdx = len; out rax = 1/0. Local
; copy -- same small helper duplicated in parser_main.asm, per this
; codebase's "small helpers get duplicated per file" convention.
; ===========================================================================
bytes_equal:
    xor     rcx, rcx
.loop:
    cmp     rcx, rdx
    jae     .yes
    mov     al, [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .no
    inc     rcx
    jmp     .loop
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ===========================================================================
; lookup_struct: in rdi = name_offset, rsi = name_len.
; out: rax = struct_table entry ptr, or 0 if not found.
; ===========================================================================
lookup_struct:
    push    r12                  ; query name_offset
    push    r13                  ; query name_len
    push    r14                  ; index
    push    r15                  ; current entry ptr
    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
.loop:
    cmp     r14, [struct_count]
    jae     .not_found
    mov     r15, r14
    imul    r15, r15, STRUCT_ENTRY_SIZE
    lea     r15, [struct_table + r15]
    cmp     qword [r15 + STE_NAME_LEN], r13
    jne     .next
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, [parser_src_buf]
    add     rsi, [r15 + STE_NAME_OFF]
    mov     rdx, r13
    call    bytes_equal
    cmp     rax, 1
    je      .found
.next:
    inc     r14
    jmp     .loop
.found:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.not_found:
    xor     rax, rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; lookup_callable: in rdi = name_offset, rsi = name_len.
; out: rax = callable_table entry ptr, or 0 if not found. Same shape as
; lookup_struct.
; ===========================================================================
lookup_callable:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
.loop:
    cmp     r14, [callable_count]
    jae     .not_found
    mov     r15, r14
    imul    r15, r15, CALLABLE_ENTRY_SIZE
    lea     r15, [callable_table + r15]
    cmp     qword [r15 + CTE_NAME_LEN], r13
    jne     .next
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, [parser_src_buf]
    add     rsi, [r15 + CTE_NAME_OFF]
    mov     rdx, r13
    call    bytes_equal
    cmp     rax, 1
    je      .found
.next:
    inc     r14
    jmp     .loop
.found:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.not_found:
    xor     rax, rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; lookup_local: in rdi = name_offset, rsi = name_len.
; out: rax = local_table entry ptr, or 0 if not found.
; ===========================================================================
lookup_local:
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     r13, rsi
    xor     r14, r14
.loop:
    cmp     r14, [local_count]
    jae     .not_found
    mov     r15, r14
    imul    r15, r15, LOCAL_ENTRY_SIZE
    lea     r15, [local_table + r15]
    cmp     qword [r15 + LTE_NAME_LEN], r13
    jne     .next
    mov     rdi, [parser_src_buf]
    add     rdi, r12
    mov     rsi, [parser_src_buf]
    add     rsi, [r15 + LTE_NAME_OFF]
    mov     rdx, r13
    call    bytes_equal
    cmp     rax, 1
    je      .found
.next:
    inc     r14
    jmp     .loop
.found:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret
.not_found:
    xor     rax, rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    ret

; ===========================================================================
; check_duplicate_top_level: in rdi = name_offset, rsi = name_len. Reports
; a semantic error and never returns if a struct or callable is already
; registered under this name; otherwise returns normally.
; ===========================================================================
check_duplicate_top_level:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    call    lookup_struct
    cmp     rax, 0
    jne     .duplicate
    mov     rdi, rbx
    mov     rsi, r12
    call    lookup_callable
    cmp     rax, 0
    jne     .duplicate
    pop     r12
    pop     rbx
    ret
.duplicate:
    call    sema_report_begin
    mov     rsi, msg_duplicate_top_level
    mov     rdx, msg_duplicate_top_level_len
    call    err_append_str
    mov     rdi, rbx
    mov     rsi, r12
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, rbx
    jmp     sema_report_finish

; ===========================================================================
; check_duplicate_local: in rdi = name_offset, rsi = name_len. Reports a
; semantic error and never returns if already registered in local_table.
; ===========================================================================
check_duplicate_local:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    call    lookup_local
    cmp     rax, 0
    je      .ok
    call    sema_report_begin
    mov     rsi, msg_duplicate_local
    mov     rdx, msg_duplicate_local_len
    call    err_append_str
    mov     rdi, rbx
    mov     rsi, r12
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, rbx
    jmp     sema_report_finish
.ok:
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; build_global_tables: in rdi = AST_PROGRAM node ptr. Populates
; struct_table/callable_table (pass 1a -- name registration + duplicate
; detection only; type validation is pass 1b, in sema_types.asm).
; ===========================================================================
build_global_tables:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     qword [struct_count], 0
    mov     qword [callable_count], 0

    mov     r12, [rbx + AST_A_OFF]        ; decls ptr
    mov     r13, [rbx + AST_B_OFF]        ; decl_count
    xor     r14, r14
.loop:
    cmp     r14, r13
    jae     .done
    mov     rax, [r12 + r14*8]            ; decl ptr
    mov     rcx, [rax + AST_KIND_OFF]
    cmp     rcx, AST_STRUCT_DECL
    je      .is_struct
    cmp     rcx, AST_FUNCTION
    je      .is_function
    cmp     rcx, AST_EXTERN_DECL
    je      .is_extern
    jmp     .next                          ; unreachable per grammar

.is_struct:
    mov     rdi, [rax + AST_A_OFF]         ; name_offset
    mov     rsi, [rax + AST_B_OFF]         ; name_len
    call    check_duplicate_top_level      ; never returns on duplicate

    mov     rax, [r12 + r14*8]             ; re-derive (call clobbered rax)
    mov     rcx, [struct_count]
    imul    rcx, rcx, STRUCT_ENTRY_SIZE
    lea     rdx, [struct_table + rcx]
    mov     rcx, [rax + AST_A_OFF]
    mov     [rdx + STE_NAME_OFF], rcx
    mov     rcx, [rax + AST_B_OFF]
    mov     [rdx + STE_NAME_LEN], rcx
    mov     [rdx + STE_DECL_PTR], rax
    inc     qword [struct_count]
    mov     rax, [struct_count]
    cmp     rax, MAX_LIST_ARITY
    jae     .too_many_structs
    jmp     .next

.is_function:
    mov     rcx, [rax + AST_A_OFF]         ; signature ptr
    mov     rdi, [rcx + AST_A_OFF]         ; name_offset
    mov     rsi, [rcx + AST_B_OFF]         ; name_len
    call    check_duplicate_top_level

    mov     rax, [r12 + r14*8]             ; re-derive decl ptr
    mov     rcx, [rax + AST_A_OFF]         ; signature ptr (re-derive)
    mov     rdx, [callable_count]
    imul    rdx, rdx, CALLABLE_ENTRY_SIZE
    lea     rdx, [callable_table + rdx]
    push    rdx
    mov     rsi, [rcx + AST_A_OFF]
    mov     [rdx + CTE_NAME_OFF], rsi
    mov     rsi, [rcx + AST_B_OFF]
    mov     [rdx + CTE_NAME_LEN], rsi
    mov     qword [rdx + CTE_IS_EXTERN], 0
    mov     [rdx + CTE_SIG_PTR], rcx
    mov     rsi, [rax + AST_B_OFF]         ; return_type
    mov     [rdx + CTE_RET_TYPE], rsi
    pop     rdx
    inc     qword [callable_count]
    mov     rax, [callable_count]
    cmp     rax, MAX_LIST_ARITY
    jae     .too_many_callables
    jmp     .next

.is_extern:
    mov     rcx, [rax + AST_A_OFF]         ; signature ptr
    mov     rdi, [rcx + AST_A_OFF]
    mov     rsi, [rcx + AST_B_OFF]
    call    check_duplicate_top_level

    mov     rax, [r12 + r14*8]
    mov     rcx, [rax + AST_A_OFF]         ; signature ptr (re-derive)
    mov     rdx, [callable_count]
    imul    rdx, rdx, CALLABLE_ENTRY_SIZE
    lea     rdx, [callable_table + rdx]
    push    rdx
    mov     rsi, [rcx + AST_A_OFF]
    mov     [rdx + CTE_NAME_OFF], rsi
    mov     rsi, [rcx + AST_B_OFF]
    mov     [rdx + CTE_NAME_LEN], rsi
    mov     qword [rdx + CTE_IS_EXTERN], 1
    mov     [rdx + CTE_SIG_PTR], rcx
    mov     rsi, [rax + AST_B_OFF]
    mov     [rdx + CTE_RET_TYPE], rsi
    pop     rdx
    inc     qword [callable_count]
    mov     rax, [callable_count]
    cmp     rax, MAX_LIST_ARITY
    jae     .too_many_callables
    jmp     .next

.next:
    inc     r14
    jmp     .loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.too_many_structs:
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_A_OFF]
    call    sema_report_begin
    mov     rsi, msg_too_many_structs
    mov     rdx, msg_too_many_structs_len
    call    err_append_str
    mov     rax, [r12 + r14*8]
    mov     rdi, [rax + AST_A_OFF]
    jmp     sema_report_finish
.too_many_callables:
    call    sema_report_begin
    mov     rsi, msg_too_many_callables
    mov     rdx, msg_too_many_callables_len
    call    err_append_str
    mov     rax, [r12 + r14*8]
    mov     rcx, [rax + AST_A_OFF]
    mov     rdi, [rcx + AST_A_OFF]
    jmp     sema_report_finish

; ===========================================================================
; build_local_table: in rdi = AST_SIGNATURE ptr, rsi = AST_FUNC_BLOCK ptr.
; Resets and rebuilds local_table from the signature's params followed by
; the func_block's decls -- one flat scope, duplicate-checked as each
; entry is added (params against params, decls against params+decls, no
; nesting to reason about).
; ===========================================================================
build_local_table:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi                       ; signature ptr
    mov     r14, rsi                       ; func_block ptr
    mov     qword [local_count], 0

    mov     r12, [rbx + AST_C_OFF]         ; params ptr
    mov     r13, [rbx + AST_D_OFF]         ; param_count
    xor     rcx, rcx
.param_loop:
    cmp     rcx, r13
    jae     .decls
    push    rcx
    mov     rax, [r12 + rcx*8]             ; AST_PARAM ptr
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, [rax + AST_B_OFF]
    call    check_duplicate_local

    pop     rcx
    push    rcx
    mov     rax, [r12 + rcx*8]
    call    append_local_entry
    pop     rcx
    inc     rcx
    jmp     .param_loop

.decls:
    mov     r12, [r14 + AST_A_OFF]         ; decls ptr
    mov     r13, [r14 + AST_B_OFF]         ; decl_count
    xor     rcx, rcx
.decl_loop:
    cmp     rcx, r13
    jae     .done
    push    rcx
    mov     rax, [r12 + rcx*8]             ; AST_DECL_MUT/CONST ptr
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, [rax + AST_B_OFF]
    call    check_duplicate_local

    pop     rcx
    push    rcx
    mov     rax, [r12 + rcx*8]
    call    append_local_entry
    pop     rcx
    inc     rcx
    jmp     .decl_loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; append_local_entry: internal helper for build_local_table. in rax =
; AST_PARAM or AST_DECL_MUT/CONST ptr (all three share the same
; name_offset(a)/name_len(b)/type(c) prefix layout). is_const is derived
; from the node's own kind (AST_PARAM is never const -- Stage 0 has no
; "const parameter" concept, params are just always-fresh-per-call values).
; Also resolves the entry's declared type here (pass 1b already resolved
; every param type via resolve_signature_types, so re-resolving a param's
; type here is a harmless, idempotent redundancy -- keeping this call
; unconditional for both params and decls is simpler than special-casing,
; and it's the only point a local decl's own type ever gets validated).
; Reports "too many parameters/declarations" and never returns on overflow.
; ===========================================================================
append_local_entry:
    push    rbx
    mov     rbx, rax                       ; source node ptr
    mov     rdi, [rbx + AST_C_OFF]
    call    resolve_type
    mov     rax, [local_count]
    imul    rax, rax, LOCAL_ENTRY_SIZE
    lea     rax, [local_table + rax]
    mov     rcx, [rbx + AST_A_OFF]
    mov     [rax + LTE_NAME_OFF], rcx
    mov     rcx, [rbx + AST_B_OFF]
    mov     [rax + LTE_NAME_LEN], rcx
    mov     rcx, [rbx + AST_C_OFF]
    mov     [rax + LTE_TYPE_PTR], rcx
    mov     rcx, [rbx + AST_KIND_OFF]
    cmp     rcx, AST_DECL_CONST
    jne     .not_const
    mov     qword [rax + LTE_IS_CONST], 1
    jmp     .stored
.not_const:
    mov     qword [rax + LTE_IS_CONST], 0
.stored:
    inc     qword [local_count]
    mov     rax, [local_count]
    cmp     rax, MAX_LIST_ARITY
    jae     .too_many
    pop     rbx
    ret
.too_many:
    call    sema_report_begin
    mov     rsi, msg_too_many_locals
    mov     rdx, msg_too_many_locals_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    jmp     sema_report_finish
