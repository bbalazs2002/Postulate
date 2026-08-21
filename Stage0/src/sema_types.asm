; Postulate Stage 0 -- semantic analyzer: type resolution and equality.
; See docs/postulate_stage0_semantics_spec.md.
;
; A "type" here is just a pointer to an existing AST_TY_* node -- usually
; one already sitting in the AST (a decl's declared type, a symbol-table
; entry's type), occasionally a freshly synthesized one (get_bool_type /
; get_int_type below, or &x's result type in sema_expr.asm) via
; ast_alloc_node. No separate canonical type representation is built.

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern ast_alloc_node
extern lookup_struct
extern bytes_equal
extern sema_report_begin
extern sema_report_finish
extern err_append_span
extern quote_char

global resolve_type
global resolve_struct_type
global resolve_all_types
global types_equal
global get_bool_type
global get_int_type
global get_null_default_type
global is_integer_type
global is_bool_type

section .bss
bool_type_node: resq 1
int_type_node:  resq 1
null_default_type_node: resq 1

section .data
msg_unknown_type: db "unknown type '"
msg_unknown_type_len equ $ - msg_unknown_type

section .text

; ===========================================================================
; resolve_struct_type: in rdi = type node ptr. out: rax = AST_STRUCT_DECL
; ptr if this is a struct-name base-type reference that resolves; 0
; otherwise -- either because the type isn't a struct-name reference at
; all (builtin base, pointer, array: not an error, just "not this shape"),
; or because it is one but the name doesn't resolve (also 0 here; it's
; resolve_type's job to actually report that as an error during pass 1b).
; ===========================================================================
resolve_struct_type:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_TY_BASE
    jne     .not_struct
    cmp     qword [rdi + AST_A_OFF], 0
    jne     .not_struct
    mov     rax, [rdi + AST_B_OFF]      ; name_offset
    mov     rcx, [rdi + AST_C_OFF]      ; name_len
    mov     rdi, rax
    mov     rsi, rcx
    call    lookup_struct
    cmp     rax, 0
    je      .not_found
    mov     rax, [rax + STE_DECL_PTR]
    ret
.not_found:
    xor     rax, rax
    ret
.not_struct:
    xor     rax, rax
    ret

; ===========================================================================
; resolve_type: in rdi = type node ptr. Recursively validates that every
; struct-name reference within it resolves to a known struct. Reports a
; semantic error and never returns on an unresolved name; otherwise
; returns normally. Requires the global struct table already built
; (build_global_tables, pass 1a) -- called for every declared type
; occurrence in the program (pass 1b: struct fields, params, return
; types; also re-run per local decl in symtab.asm's append_local_entry).
; ===========================================================================
resolve_type:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_TY_POINTER
    je      .pointer
    cmp     rax, AST_TY_ARRAY
    je      .array
    ; AST_TY_BASE
    cmp     qword [rbx + AST_A_OFF], 0
    jne     .ok                        ; builtin tag != 0 -- always valid
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, [rbx + AST_C_OFF]
    call    lookup_struct
    cmp     rax, 0
    jne     .ok
    call    sema_report_begin
    mov     rsi, msg_unknown_type
    mov     rdx, msg_unknown_type_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, [rbx + AST_C_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    jmp     sema_report_finish
.ok:
    pop     rbx
    ret
.pointer:
    mov     rdi, [rbx + AST_A_OFF]
    call    resolve_type
    pop     rbx
    ret
.array:
    mov     rdi, [rbx + AST_A_OFF]
    call    resolve_type
    pop     rbx
    ret

; ===========================================================================
; resolve_struct_fields: internal. in rdi = AST_STRUCT_DECL ptr. Resolves
; every field's declared type.
; ===========================================================================
resolve_struct_fields:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, [rbx + AST_C_OFF]      ; fields ptr
    mov     r13, [rbx + AST_D_OFF]      ; field_count
    xor     r14, r14
.loop:
    cmp     r14, r13
    jae     .done
    mov     rax, [r12 + r14*8]          ; AST_FIELD_DECL ptr
    mov     rdi, [rax + AST_C_OFF]      ; type ptr
    call    resolve_type
    inc     r14
    jmp     .loop
.done:
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; resolve_signature_types: internal. in rdi = AST_FUNCTION or
; AST_EXTERN_DECL ptr (both share the a=signature layout). Resolves every
; param's declared type.
; ===========================================================================
resolve_signature_types:
    push    rbx
    push    r12
    push    r13
    mov     rax, [rdi + AST_A_OFF]      ; signature ptr
    mov     r12, [rax + AST_C_OFF]      ; params ptr
    mov     r13, [rax + AST_D_OFF]      ; param_count
    xor     rbx, rbx
.loop:
    cmp     rbx, r13
    jae     .done
    mov     rax, [r12 + rbx*8]          ; AST_PARAM ptr
    mov     rdi, [rax + AST_C_OFF]      ; type ptr
    call    resolve_type
    inc     rbx
    jmp     .loop
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; resolve_all_types: in rdi = AST_PROGRAM ptr. Pass 1b: walks every struct
; field, every function/extern param, and every function/extern return
; type, resolving each. Run after build_global_tables (pass 1a) so
; forward/mutual references between top-level declarations resolve
; regardless of declaration order. A function's own local decls are
; resolved separately, per-function, when its local table is built
; (symtab.asm's append_local_entry) -- no need to visit them here too.
; ===========================================================================
resolve_all_types:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, [rbx + AST_A_OFF]      ; decls ptr
    mov     r13, [rbx + AST_B_OFF]      ; decl_count
    xor     r14, r14
.loop:
    cmp     r14, r13
    jae     .done
    mov     rax, [r12 + r14*8]
    mov     rcx, [rax + AST_KIND_OFF]
    cmp     rcx, AST_STRUCT_DECL
    je      .struct_decl
    cmp     rcx, AST_FUNCTION
    je      .function
    cmp     rcx, AST_EXTERN_DECL
    je      .extern_decl
    jmp     .next
.struct_decl:
    mov     rdi, [r12 + r14*8]
    call    resolve_struct_fields
    jmp     .next
.function:
    mov     rdi, [r12 + r14*8]
    call    resolve_signature_types
    mov     rax, [r12 + r14*8]
    mov     rax, [rax + AST_B_OFF]      ; return_type, 0 = void
    cmp     rax, 0
    je      .next
    mov     rdi, rax
    call    resolve_type
    jmp     .next
.extern_decl:
    mov     rdi, [r12 + r14*8]
    call    resolve_signature_types
    mov     rax, [r12 + r14*8]
    mov     rax, [rax + AST_B_OFF]
    cmp     rax, 0
    je      .next
    mov     rdi, rax
    call    resolve_type
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

; ===========================================================================
; types_equal: in rdi = t1, rsi = t2 (both AST_TY_* node ptrs).
; out: rax = 1/0. Structural comparison, with int<->int16 / uint<->uint16
; folded (different TOK_KW_* tags, same underlying type -- main spec
; "int/uint" row). Struct-name BASE types compare by name span.
; ===========================================================================
types_equal:
    push    rbx
    push    r12
    ; a 0 ("void") on either side is never equal to anything, including
    ; another 0 -- in this codebase 0 only ever appears here as the
    ; result of check_expr on a void-returning call used as a value,
    ; which is always wrong; declared/expected types (the other operand
    ; in every real call site) are never 0, `type` has no void alternative.
    cmp     rdi, 0
    je      .not_equal_early
    cmp     rsi, 0
    je      .not_equal_early
    mov     rbx, rdi
    mov     r12, rsi
    mov     rax, [rbx + AST_KIND_OFF]
    mov     rcx, [r12 + AST_KIND_OFF]
    cmp     rax, rcx
    jne     .not_equal
    cmp     rax, AST_TY_BASE
    je      .base
    cmp     rax, AST_TY_POINTER
    je      .pointer
    cmp     rax, AST_TY_ARRAY
    je      .array
    jmp     .not_equal              ; unknown kind, defensive
.base:
    mov     rax, [rbx + AST_A_OFF]  ; t1 tag
    mov     rcx, [r12 + AST_A_OFF]  ; t2 tag
    cmp     rax, 0
    jne     .base_builtin
    cmp     rcx, 0
    jne     .not_equal
    ; both struct-name references -- compare name spans
    mov     rdx, [rbx + AST_C_OFF]
    cmp     rdx, [r12 + AST_C_OFF]
    jne     .not_equal
    mov     rdi, [parser_src_buf]
    add     rdi, [rbx + AST_B_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, [r12 + AST_B_OFF]
    call    bytes_equal
    jmp     .done
.base_builtin:
    cmp     rcx, 0
    je      .not_equal
    cmp     rax, rcx
    je      .equal
    cmp     rax, TOK_KW_INT
    jne     .check_int_rev
    cmp     rcx, TOK_KW_INT16
    je      .equal
    jmp     .check_uint
.check_int_rev:
    cmp     rax, TOK_KW_INT16
    jne     .check_uint
    cmp     rcx, TOK_KW_INT
    je      .equal
    jmp     .not_equal
.check_uint:
    cmp     rax, TOK_KW_UINT
    jne     .check_uint_rev
    cmp     rcx, TOK_KW_UINT16
    je      .equal
    jmp     .not_equal
.check_uint_rev:
    cmp     rax, TOK_KW_UINT16
    jne     .not_equal
    cmp     rcx, TOK_KW_UINT
    je      .equal
    jmp     .not_equal
.pointer:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [r12 + AST_A_OFF]
    call    types_equal
    jmp     .done
.array:
    mov     rax, [rbx + AST_B_OFF]
    cmp     rax, [r12 + AST_B_OFF]
    jne     .not_equal
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [r12 + AST_A_OFF]
    call    types_equal
    jmp     .done
.equal:
    mov     rax, 1
    jmp     .done
.not_equal:
    xor     rax, rax
.done:
    pop     r12
    pop     rbx
    ret
.not_equal_early:
    xor     rax, rax
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; get_bool_type: out rax = a shared, canonical AST_TY_BASE{bool} node ptr,
; allocated once and cached -- every "this must be bool" check point (if/
; while conditions, comparison/logic op results) shares one node instead
; of allocating a fresh one each time.
; ===========================================================================
get_bool_type:
    cmp     qword [bool_type_node], 0
    jne     .have_it
    mov     rdi, AST_TY_BASE
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], TOK_KW_BOOL
    mov     qword [rax + AST_B_OFF], 0
    mov     qword [rax + AST_C_OFF], 0
    mov     [bool_type_node], rax
.have_it:
    mov     rax, [bool_type_node]
    ret

; ===========================================================================
; get_int_type: out rax = a shared, canonical AST_TY_BASE{int} node ptr --
; the fallback type for a bare integer literal with no expected-type
; context anywhere in its enclosing expression (e.g. a bare `5 + 6;`
; expression statement).
; ===========================================================================
get_int_type:
    cmp     qword [int_type_node], 0
    jne     .have_it
    mov     rdi, AST_TY_BASE
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], TOK_KW_INT
    mov     qword [rax + AST_B_OFF], 0
    mov     qword [rax + AST_C_OFF], 0
    mov     [int_type_node], rax
.have_it:
    mov     rax, [int_type_node]
    ret

; ===========================================================================
; get_null_default_type: out rax = a shared, canonical `*int8` node ptr --
; the fallback type for a bare `null` literal with no pointer-typed
; context anywhere in its enclosing expression (rare in practice: every
; decl/param/field type is always explicit in this language, so this only
; matters for a genuinely context-free position like a bare `null;`
; expression statement).
; ===========================================================================
get_null_default_type:
    cmp     qword [null_default_type_node], 0
    jne     .have_it
    mov     rdi, AST_TY_BASE
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], TOK_KW_INT8
    mov     qword [rax + AST_B_OFF], 0
    mov     qword [rax + AST_C_OFF], 0
    mov     rcx, rax
    mov     rdi, AST_TY_POINTER
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], rcx
    mov     [null_default_type_node], rax
.have_it:
    mov     rax, [null_default_type_node]
    ret

; ===========================================================================
; is_integer_type: in rdi = type node ptr. out rax = 1/0 -- true iff a
; builtin integer base type (int8..uint64, tokens.inc's contiguous
; TOK_KW_INT8..TOK_KW_UINT64 range -- excludes TOK_KW_BOOL, which
; immediately follows that range).
; ===========================================================================
is_integer_type:
    cmp     rdi, 0
    je      .no
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_TY_BASE
    jne     .no
    mov     rax, [rdi + AST_A_OFF]
    cmp     rax, TOK_KW_INT8
    jl      .no
    cmp     rax, TOK_KW_UINT64
    jg      .no
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ===========================================================================
; is_bool_type: in rdi = type node ptr. out rax = 1/0.
; ===========================================================================
is_bool_type:
    cmp     rdi, 0
    je      .no
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_TY_BASE
    jne     .no
    cmp     qword [rdi + AST_A_OFF], TOK_KW_BOOL
    jne     .no
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret
