; Postulate Stage 0 -- semantic analyzer: expression type checking.
; See docs/postulate_stage0_semantics_spec.md.
;
; check_expr(node, expected_type) -> resolved type ptr. `expected_type`
; (0 = none) is only ever actually consumed by literal nodes (INT/BOOL/
; NULL have no fixed type of their own -- no literal suffixes exist in
; this grammar, ld. spec gap #1) and by array_literal (to learn its
; element type from context, since it carries no type annotation of its
; own). Every other node kind determines its own type structurally and
; ignores `expected_type` -- callers that need an exact match (decl init,
; assignment, return, call args) run types_equal themselves afterward.
;
; check_expr pushes rbx/r12/r13/r14/r15 unconditionally at entry and
; reuses them freely for whatever the current branch needs -- not held to
; one meaning for the whole routine, only restored (for the caller) at
; the very end. This is safe precisely because every nested call this
; file makes (check_expr itself, types_equal, lookup_*, resolve_*) also
; protects its own r12-r15/rbx at its own frame boundary (the section-9.7
; convention from the parser phases, carried forward here).

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern ast_alloc_node
extern bytes_equal
extern lookup_local
extern lookup_struct
extern lookup_callable
extern resolve_struct_type
extern types_equal
extern get_bool_type
extern get_int_type
extern get_null_default_type
extern is_integer_type
extern is_bool_type
extern sema_report_begin
extern sema_report_finish
extern err_append_span
extern quote_char

global check_expr
global find_offset
global is_valid_lvalue

section .data
msg_undeclared_ident:  db "undeclared identifier '"
msg_undeclared_ident_len equ $ - msg_undeclared_ident
msg_expected_bool:         db "expected 'bool'"
msg_expected_bool_len      equ $ - msg_expected_bool
msg_expected_integer:         db "expected an integer type"
msg_expected_integer_len      equ $ - msg_expected_integer
msg_binary_type_mismatch:        db "binary operator operand type mismatch"
msg_binary_type_mismatch_len     equ $ - msg_binary_type_mismatch
msg_deref_non_pointer:               db "cannot dereference a non-pointer type"
msg_deref_non_pointer_len            equ $ - msg_deref_non_pointer
msg_addr_of_non_lvalue:                 db "'&' requires an lvalue operand"
msg_addr_of_non_lvalue_len              equ $ - msg_addr_of_non_lvalue
msg_index_non_array:                       db "cannot index a non-array type"
msg_index_non_array_len                    equ $ - msg_index_non_array
msg_index_non_integer:                        db "array index must be an integer type"
msg_index_non_integer_len                     equ $ - msg_index_non_integer
msg_field_non_struct:                            db "field access on a non-struct type"
msg_field_non_struct_len                         equ $ - msg_field_non_struct
msg_unknown_field:                                  db "no such field '"
msg_unknown_field_len                               equ $ - msg_unknown_field
msg_call_non_function:                                 db "cannot call a non-function value"
msg_call_non_function_len                              equ $ - msg_call_non_function
msg_undeclared_function:                                  db "undeclared function '"
msg_undeclared_function_len                               equ $ - msg_undeclared_function
msg_arg_count_mismatch:                                      db "wrong number of arguments in call to '"
msg_arg_count_mismatch_len                                   equ $ - msg_arg_count_mismatch
msg_arg_type_mismatch:                                          db "argument type mismatch in call to '"
msg_arg_type_mismatch_len                                       equ $ - msg_arg_type_mismatch
msg_unknown_type:                                                  db "unknown type '"
msg_unknown_type_len                                               equ $ - msg_unknown_type
msg_field_type_mismatch:                                              db "field initializer type mismatch"
msg_field_type_mismatch_len                                          equ $ - msg_field_type_mismatch
msg_array_elem_type_mismatch:                                            db "array element type mismatch"
msg_array_elem_type_mismatch_len                                         equ $ - msg_array_elem_type_mismatch

section .text

; ===========================================================================
; find_offset: in rdi = any expr node ptr. out: rax = a representative
; source byte offset for it. IDENT/INT/BOOL/NULL/FIELD carry their own
; span directly; every other composite kind recurses into a designated
; child until it bottoms out at one of those. Used whenever a diagnostic
; needs *some* precise position for an expression that doesn't carry one
; itself (BINARY, UNARY, INDEX, CALL, STRUCT_LIT, ARRAY_LIT).
; ===========================================================================
find_offset:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .self_a
    cmp     rax, AST_EX_INT
    je      .self_b
    cmp     rax, AST_EX_BOOL
    je      .self_b
    cmp     rax, AST_EX_NULL
    je      .self_a
    cmp     rax, AST_EX_FIELD
    je      .self_b
    cmp     rax, AST_EX_UNARY
    je      .child_b
    cmp     rax, AST_EX_BINARY
    je      .child_b
    cmp     rax, AST_EX_INDEX
    je      .child_a
    cmp     rax, AST_EX_CALL
    je      .child_a
    cmp     rax, AST_EX_STRUCT_LIT
    je      .self_a
    cmp     rax, AST_EX_ARRAY_LIT
    je      .array_lit_fallback
    cmp     rax, AST_FIELD_INIT
    je      .self_a
    cmp     rax, AST_STMT_EXPR
    je      .child_a
    cmp     rax, AST_STMT_RETURN
    je      .return_stmt_fallback
    xor     rax, rax
    ret
.return_stmt_fallback:
    ; STMT_RETURN's a = expr (0 if absent) -- recurse into it if present,
    ; else fall back to the statement's own b = the 'return' keyword's
    ; source offset (the only stmt kind that carries one, ld.
    ; stmt_parser.asm's parse_return_stmt).
    mov     rax, [rdi + AST_A_OFF]
    cmp     rax, 0
    jne     .return_has_expr
    mov     rax, [rdi + AST_B_OFF]
    ret
.return_has_expr:
    mov     rdi, rax
    jmp     find_offset
.self_a:
    mov     rax, [rdi + AST_A_OFF]
    ret
.self_b:
    mov     rax, [rdi + AST_B_OFF]
    ret
.child_a:
    mov     rdi, [rdi + AST_A_OFF]
    jmp     find_offset
.child_b:
    mov     rdi, [rdi + AST_B_OFF]
    jmp     find_offset
.array_lit_fallback:
    mov     rax, [rdi + AST_B_OFF]      ; elem_count
    cmp     rax, 0
    je      .give_up
    mov     rax, [rdi + AST_A_OFF]      ; elems ptr
    mov     rdi, [rax]                  ; first element
    jmp     find_offset
.give_up:
    xor     rax, rax
    ret

; ===========================================================================
; is_literal_expr: internal. in rdi = expr node ptr. out rax = 1/0 --
; true for INT/BOOL/NULL (the only node kinds with no fixed type of their
; own, ld. gap #1).
; ===========================================================================
is_literal_expr:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_EX_INT
    je      .yes
    cmp     rax, AST_EX_BOOL
    je      .yes
    cmp     rax, AST_EX_NULL
    je      .yes
    xor     rax, rax
    ret
.yes:
    mov     rax, 1
    ret

; ===========================================================================
; is_valid_lvalue: in rdi = expr node ptr. out: rax = 1/0. Structurally
; permissive beyond the literal `lvalue` EBNF text (spec gap #2) -- valid
; iff built only from IDENT/UNARY(*)/INDEX/FIELD nodes, bottoming out at
; a plain identifier. Accepts "(*arr)[i]" naturally, which the formal
; grammar rule as written doesn't obviously cover but which is exactly
; the idiom the *(T[N]) pointer-array design exists to support.
; ===========================================================================
is_valid_lvalue:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .yes
    cmp     rax, AST_EX_INDEX
    je      .check_a
    cmp     rax, AST_EX_FIELD
    je      .check_a
    cmp     rax, AST_EX_UNARY
    je      .check_unary
    xor     rax, rax
    ret
.check_a:
    mov     rdi, [rdi + AST_A_OFF]
    jmp     is_valid_lvalue
.check_unary:
    mov     rax, [rdi + AST_A_OFF]      ; op
    cmp     rax, TOK_STAR
    jne     .no
    mov     rdi, [rdi + AST_B_OFF]      ; operand
    jmp     is_valid_lvalue
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ===========================================================================
; check_expr: in rdi = AST_EX_* node ptr, rsi = expected type ptr (0 =
; none). out: rax = resolved type ptr. Reports a semantic error and never
; returns on any violation found along the way.
; ===========================================================================
check_expr:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                   ; node
    mov     r12, rsi                   ; expected_type (may be 0)
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .ident
    cmp     rax, AST_EX_INT
    je      .int
    cmp     rax, AST_EX_BOOL
    je      .bool
    cmp     rax, AST_EX_NULL
    je      .null
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
    call    get_int_type                ; unknown kind: defensive fallback
    jmp     .exit

; --- IDENT: Stage 0 has no global mutable variables, so a bare
; identifier only ever resolves against the local (per-function) table.
.ident:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    lookup_local
    cmp     rax, 0
    jne     .ident_found
    call    sema_report_begin
    mov     rsi, msg_undeclared_ident
    mov     rdx, msg_undeclared_ident_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    jmp     sema_report_finish
.ident_found:
    mov     rax, [rax + LTE_TYPE_PTR]
    jmp     .exit

; --- INT: adopts expected_type if it's an integer type; else defaults.
; No error branch here -- an inappropriate expected_type just means the
; default is used instead, and the caller's own types_equal check (decl
; init, assignment, return, argument, ...) reports the mismatch with
; better context than a literal-specific message could.
.int:
    cmp     r12, 0
    je      .int_default
    mov     rdi, r12
    call    is_integer_type
    cmp     rax, 0
    je      .int_default
    mov     rax, r12
    jmp     .exit
.int_default:
    call    get_int_type
    jmp     .exit

; --- BOOL: always bool, no context needed.
.bool:
    call    get_bool_type
    jmp     .exit

; --- NULL: adopts expected_type if it's a pointer type; else a generic
; *int8 default (rare in practice -- every declared type in this
; language is explicit, so this only matters for a context-free position
; like a bare `null;` statement).
.null:
    cmp     r12, 0
    je      .null_default
    mov     rax, [r12 + AST_KIND_OFF]
    cmp     rax, AST_TY_POINTER
    jne     .null_default
    mov     rax, r12
    jmp     .exit
.null_default:
    call    get_null_default_type
    jmp     .exit

; --- UNARY: dispatch on operator.
.unary:
    mov     rax, [rbx + AST_A_OFF]
    cmp     rax, TOK_STAR
    je      .unary_deref
    cmp     rax, TOK_AMP
    je      .unary_addr
    cmp     rax, TOK_BANG
    je      .unary_not
    jmp     .unary_neg                  ; TOK_MINUS

.unary_not:
    call    get_bool_type
    mov     r13, rax
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    call    is_bool_type
    cmp     rax, 0
    jne     .unary_not_ok
    call    sema_report_begin
    mov     rsi, msg_expected_bool
    mov     rdx, msg_expected_bool_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.unary_not_ok:
    mov     rax, r13
    jmp     .exit

.unary_neg:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r12
    call    check_expr
    mov     r13, rax
    mov     rdi, r13
    call    is_integer_type
    cmp     rax, 0
    jne     .unary_neg_ok
    call    sema_report_begin
    mov     rsi, msg_expected_integer
    mov     rdx, msg_expected_integer_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.unary_neg_ok:
    mov     rax, r13
    jmp     .exit

.unary_deref:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, 0
    call    check_expr
    mov     r13, rax
    mov     rax, [r13 + AST_KIND_OFF]
    cmp     rax, AST_TY_POINTER
    je      .unary_deref_ok
    call    sema_report_begin
    mov     rsi, msg_deref_non_pointer
    mov     rdx, msg_deref_non_pointer_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.unary_deref_ok:
    mov     rax, [r13 + AST_A_OFF]
    jmp     .exit

.unary_addr:
    mov     rdi, [rbx + AST_B_OFF]
    call    is_valid_lvalue
    cmp     rax, 0
    jne     .unary_addr_ok
    call    sema_report_begin
    mov     rsi, msg_addr_of_non_lvalue
    mov     rdx, msg_addr_of_non_lvalue_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.unary_addr_ok:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, 0
    call    check_expr
    mov     r13, rax
    mov     rdi, AST_TY_POINTER
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r13
    jmp     .exit

; --- BINARY: dispatch on operator into logic / comparison / arithmetic.
.binary:
    mov     rax, [rbx + AST_A_OFF]
    cmp     rax, TOK_ANDAND
    je      .binary_logic
    cmp     rax, TOK_OROR
    je      .binary_logic
    cmp     rax, TOK_EQ
    je      .binary_compare
    cmp     rax, TOK_NE
    je      .binary_compare
    cmp     rax, TOK_LT
    je      .binary_compare
    cmp     rax, TOK_GT
    je      .binary_compare
    cmp     rax, TOK_LE
    je      .binary_compare
    cmp     rax, TOK_GE
    je      .binary_compare
    jmp     .binary_arith

.binary_logic:
    call    get_bool_type
    mov     r13, rax
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    call    is_bool_type
    cmp     rax, 0
    je      .binary_logic_bad
    mov     rdi, [rbx + AST_C_OFF]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    call    is_bool_type
    cmp     rax, 0
    je      .binary_logic_bad
    mov     rax, r13
    jmp     .exit
.binary_logic_bad:
    call    sema_report_begin
    mov     rsi, msg_expected_bool
    mov     rdx, msg_expected_bool_len
    call    err_append_str
    mov     rdi, rbx
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish

.binary_compare:
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, 0
    call    check_expr
    mov     r13, rax
    mov     rdi, [rbx + AST_C_OFF]
    mov     rsi, r13
    call    check_expr
    mov     r14, rax
    mov     rdi, r13
    mov     rsi, r14
    call    types_equal
    cmp     rax, 0
    jne     .binary_compare_ok
    call    sema_report_begin
    mov     rsi, msg_binary_type_mismatch
    mov     rdx, msg_binary_type_mismatch_len
    call    err_append_str
    mov     rdi, rbx
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.binary_compare_ok:
    call    get_bool_type
    jmp     .exit

; Arithmetic/bitwise/shift: whichever operand is NOT a bare literal
; anchors the other's type (checked first, its result used as the other
; side's expected_type) -- see spec gap #1. If both are literals, the
; outer expected_type (r12) anchors the first one checked, which then
; anchors the second.
.binary_arith:
    mov     rdi, [rbx + AST_B_OFF]
    call    is_literal_expr
    cmp     rax, 0
    jne     .arith_left_is_literal
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r12
    call    check_expr
    mov     r13, rax
    mov     rdi, [rbx + AST_C_OFF]
    mov     rsi, r13
    call    check_expr
    mov     r14, rax
    jmp     .arith_compare
.arith_left_is_literal:
    mov     rdi, [rbx + AST_C_OFF]
    mov     rsi, r12
    call    check_expr
    mov     r14, rax
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, r14
    call    check_expr
    mov     r13, rax
.arith_compare:
    mov     rdi, r13
    mov     rsi, r14
    call    types_equal
    cmp     rax, 0
    jne     .binary_arith_ok
    call    sema_report_begin
    mov     rsi, msg_binary_type_mismatch
    mov     rdx, msg_binary_type_mismatch_len
    call    err_append_str
    mov     rdi, rbx
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.binary_arith_ok:
    mov     rax, r13
    jmp     .exit

; --- INDEX: base must be an array type; index must be some integer type.
.index:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_expr
    mov     r13, rax
    mov     rax, [r13 + AST_KIND_OFF]
    cmp     rax, AST_TY_ARRAY
    je      .index_base_ok
    call    sema_report_begin
    mov     rsi, msg_index_non_array
    mov     rdx, msg_index_non_array_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.index_base_ok:
    mov     r14, [r13 + AST_A_OFF]      ; element type
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, 0
    call    check_expr
    mov     rdi, rax
    call    is_integer_type
    cmp     rax, 0
    jne     .index_ok
    call    sema_report_begin
    mov     rsi, msg_index_non_integer
    mov     rdx, msg_index_non_integer_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.index_ok:
    mov     rax, r14
    jmp     .exit

; --- FIELD: base must resolve to a struct type; field must exist on it.
.field:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, 0
    call    check_expr
    mov     rdi, rax
    call    resolve_struct_type
    cmp     rax, 0
    jne     .field_base_ok
    call    sema_report_begin
    mov     rsi, msg_field_non_struct
    mov     rdx, msg_field_non_struct_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.field_base_ok:
    mov     r13, [rax + AST_D_OFF]      ; struct's field_count
    mov     r15, [rax + AST_C_OFF]      ; struct's fields ptr
    xor     r14, r14                    ; scan index
.field_scan:
    cmp     r14, r13
    jae     .field_not_found
    mov     rax, [r15 + r14*8]          ; AST_FIELD_DECL ptr
    mov     rcx, [rax + AST_B_OFF]      ; field name_len
    cmp     rcx, [rbx + AST_C_OFF]      ; our FIELD node's name_len
    jne     .field_next
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, [rbx + AST_B_OFF]
    mov     rdx, rcx
    call    bytes_equal
    cmp     rax, 1
    je      .field_found
.field_next:
    inc     r14
    jmp     .field_scan
.field_found:
    mov     rax, [r15 + r14*8]
    mov     rax, [rax + AST_C_OFF]      ; field's declared type
    jmp     .exit
.field_not_found:
    call    sema_report_begin
    mov     rsi, msg_unknown_field
    mov     rdx, msg_unknown_field_len
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    mov     rsi, [rbx + AST_C_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [rbx + AST_B_OFF]
    jmp     sema_report_finish

; --- CALL: callee must be a bare identifier resolving to a known
; function/extern; arg count and each arg's type must match.
.call:
    mov     r13, [rbx + AST_A_OFF]      ; callee node
    mov     rax, [r13 + AST_KIND_OFF]
    cmp     rax, AST_EX_IDENT
    je      .call_ident
    call    sema_report_begin
    mov     rsi, msg_call_non_function
    mov     rdx, msg_call_non_function_len
    call    err_append_str
    mov     rdi, r13
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.call_ident:
    mov     rdi, [r13 + AST_A_OFF]
    mov     rsi, [r13 + AST_B_OFF]
    call    lookup_callable
    cmp     rax, 0
    jne     .call_found
    call    sema_report_begin
    mov     rsi, msg_undeclared_function
    mov     rdx, msg_undeclared_function_len
    call    err_append_str
    mov     rdi, [r13 + AST_A_OFF]
    mov     rsi, [r13 + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [r13 + AST_A_OFF]
    jmp     sema_report_finish
.call_found:
    mov     r14, rax                    ; callable_table entry ptr
    mov     rcx, [r14 + CTE_SIG_PTR]
    mov     r15, [rcx + AST_D_OFF]      ; declared param_count
    mov     rax, [rbx + AST_C_OFF]      ; actual arg_count
    cmp     rax, r15
    je      .call_argcount_ok
    call    sema_report_begin
    mov     rsi, msg_arg_count_mismatch
    mov     rdx, msg_arg_count_mismatch_len
    call    err_append_str
    mov     rdi, [r13 + AST_A_OFF]
    mov     rsi, [r13 + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, r13
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.call_argcount_ok:
    mov     rcx, [r14 + CTE_SIG_PTR]
    mov     r12, [rcx + AST_C_OFF]      ; params ptr (expected_type no
                                         ; longer needed in this branch)
    mov     r14, [rbx + AST_B_OFF]      ; args ptr
    mov     r15, [rbx + AST_C_OFF]      ; arg_count
    xor     rbx, rbx                    ; index (node ptr no longer
                                         ; needed within this branch --
                                         ; r13 still holds the callee for
                                         ; error messages)
.call_arg_loop:
    cmp     rbx, r15
    jae     .call_args_matched
    mov     rax, [r12 + rbx*8]          ; AST_PARAM ptr
    mov     rax, [rax + AST_C_OFF]      ; param's declared type
    mov     rdi, [r14 + rbx*8]          ; actual arg expr
    mov     rsi, rax
    call    check_expr
    mov     rdi, rax
    mov     rax, [r12 + rbx*8]
    mov     rsi, [rax + AST_C_OFF]
    call    types_equal
    cmp     rax, 0
    jne     .call_arg_ok
    call    sema_report_begin
    mov     rsi, msg_arg_type_mismatch
    mov     rdx, msg_arg_type_mismatch_len
    call    err_append_str
    mov     rdi, [r13 + AST_A_OFF]
    mov     rsi, [r13 + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [r14 + rbx*8]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.call_arg_ok:
    inc     rbx
    jmp     .call_arg_loop
.call_args_matched:
    ; result type = the callable's return type (0 = void). A void call
    ; used as a value elsewhere is caught uniformly by types_equal's
    ; 0-guard wherever the result actually gets compared against a real
    ; type -- no special case needed here. r14 was repurposed as the args
    ; ptr above and r12 as the params ptr, so the callable_table entry
    ; itself wasn't kept around -- cheap enough to look up once more.
    mov     rdi, [r13 + AST_A_OFF]
    mov     rsi, [r13 + AST_B_OFF]
    call    lookup_callable
    mov     rax, [rax + CTE_RET_TYPE]
    jmp     .exit

; --- STRUCT_LIT: name must resolve to a known struct; each field_init's
; value checked against that field's declared type; unknown field names
; rejected. (Completeness -- every field present exactly once -- is
; deferred, ld. plan/spec scope.)
.struct_lit:
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    lookup_struct
    cmp     rax, 0
    jne     .struct_lit_found
    call    sema_report_begin
    mov     rsi, msg_unknown_type
    mov     rdx, msg_unknown_type_len
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    mov     rsi, [rbx + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rdi, [rbx + AST_A_OFF]
    jmp     sema_report_finish
.struct_lit_found:
    mov     r13, [rax + STE_DECL_PTR]   ; AST_STRUCT_DECL
    sub     rsp, 32                     ; stable scratch region -- addressed
                                         ; only via r14 below, never via
                                         ; raw rsp, so it survives any
                                         ; number of nested calls unharmed
    mov     r14, rsp
    mov     rax, [rbx + AST_C_OFF]
    mov     [r14 + 0], rax              ; field_inits ptr
    mov     rax, [rbx + AST_D_OFF]
    mov     [r14 + 8], rax              ; count
    mov     qword [r14 + 16], 0         ; index
.struct_lit_loop:
    mov     rax, [r14 + 16]
    cmp     rax, [r14 + 8]
    jae     .struct_lit_done
    mov     rcx, [r14 + 0]
    mov     rax, [rcx + rax*8]          ; AST_FIELD_INIT ptr
    mov     [r14 + 24], rax             ; current field_init ptr
    mov     rcx, [r13 + AST_C_OFF]      ; struct's fields ptr
    mov     rdx, [r13 + AST_D_OFF]      ; struct's field_count
    xor     r15, r15
.struct_field_scan:
    cmp     r15, rdx
    jae     .struct_field_not_found
    mov     rax, [rcx + r15*8]          ; AST_FIELD_DECL ptr
    mov     r8, [r14 + 24]
    mov     r9, [rax + AST_B_OFF]       ; field_decl name_len
    cmp     r9, [r8 + AST_B_OFF]        ; field_init name_len
    jne     .struct_field_scan_next
    push    rax                        ; field_decl ptr -- balanced by the
                                        ; single pop right below
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, [r8 + AST_A_OFF]
    mov     rdx, r9
    call    bytes_equal
    pop     rcx
    cmp     rax, 1
    je      .struct_field_found
.struct_field_scan_next:
    inc     r15
    jmp     .struct_field_scan
.struct_field_found:
    ; rcx (the matched field_decl ptr) is caller-saved -- save the type
    ; we need from it into r12 (unused anywhere else in this branch)
    ; BEFORE the nested check_expr call, which clobbers rcx along with
    ; every other caller-saved register. Reading [rcx + ...] a second
    ; time after the call (as an earlier draft of this code did) crashed
    ; on the compiler-scale black-box program -- same bug class as the
    ; ast_dump.asm emit_str-clobbers-rax lesson, just with rcx instead.
    mov     r12, [rcx + AST_C_OFF]      ; field's declared type
    mov     rdi, [r14 + 24]
    mov     rdi, [rdi + AST_C_OFF]      ; field_init's value expr
    mov     rsi, r12
    call    check_expr
    mov     rdi, rax
    mov     rsi, r12
    call    types_equal
    cmp     rax, 0
    jne     .struct_field_ok
    call    sema_report_begin
    mov     rsi, msg_field_type_mismatch
    mov     rdx, msg_field_type_mismatch_len
    call    err_append_str
    mov     rdi, [r14 + 24]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.struct_field_ok:
    mov     rax, [r14 + 16]
    inc     rax
    mov     [r14 + 16], rax
    jmp     .struct_lit_loop
.struct_field_not_found:
    call    sema_report_begin
    mov     rsi, msg_unknown_field
    mov     rdx, msg_unknown_field_len
    call    err_append_str
    mov     rax, [r14 + 24]
    mov     rdi, [rax + AST_A_OFF]
    mov     rsi, [rax + AST_B_OFF]
    call    err_append_span
    mov     rsi, quote_char
    mov     rdx, 1
    call    err_append_str
    mov     rax, [r14 + 24]
    mov     rdi, [rax + AST_A_OFF]
    jmp     sema_report_finish
.struct_lit_done:
    add     rsp, 32
    mov     rdi, AST_TY_BASE
    call    ast_alloc_node
    mov     qword [rax + AST_A_OFF], 0
    mov     rcx, [rbx + AST_A_OFF]
    mov     [rax + AST_B_OFF], rcx
    mov     rcx, [rbx + AST_B_OFF]
    mov     [rax + AST_C_OFF], rcx
    jmp     .exit

; --- ARRAY_LIT: each element checked against the array's element type,
; taken from expected_type (must be an AST_TY_ARRAY). No usable context
; falls back to `int` per element (best-effort; count/completeness is
; deferred regardless, ld. plan/spec scope, so this soft spot never
; produces a wrong *crash*, only a skipped completeness check).
.array_lit:
    cmp     r12, 0
    je      .array_lit_no_context
    mov     rax, [r12 + AST_KIND_OFF]
    cmp     rax, AST_TY_ARRAY
    jne     .array_lit_no_context
    mov     r13, [r12 + AST_A_OFF]      ; element type
    jmp     .array_lit_have_type
.array_lit_no_context:
    call    get_int_type
    mov     r13, rax
.array_lit_have_type:
    mov     r14, [rbx + AST_A_OFF]      ; elems ptr
    mov     r15, [rbx + AST_B_OFF]      ; elem_count
    xor     rbx, rbx                    ; index (node ptr no longer needed)
.array_lit_loop:
    cmp     rbx, r15
    jae     .array_lit_done
    mov     rdi, [r14 + rbx*8]
    mov     rsi, r13
    call    check_expr
    mov     rdi, rax
    mov     rsi, r13
    call    types_equal
    cmp     rax, 0
    jne     .array_lit_elem_ok
    call    sema_report_begin
    mov     rsi, msg_array_elem_type_mismatch
    mov     rdx, msg_array_elem_type_mismatch_len
    call    err_append_str
    mov     rdi, [r14 + rbx*8]
    call    find_offset
    mov     rdi, rax
    jmp     sema_report_finish
.array_lit_elem_ok:
    inc     rbx
    jmp     .array_lit_loop
.array_lit_done:
    mov     rdi, AST_TY_ARRAY
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], r13
    mov     [rax + AST_B_OFF], r15
    jmp     .exit

.exit:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
