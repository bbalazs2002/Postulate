; Postulate Stage 0 -- code generator: type sizes, signedness, struct layout.
; See docs/postulate_stage0_codegen_spec.md.
;
; Packed struct layout (no padding, ld. spec) -- field_offset is a plain
; running-sum accumulator, no alignment rounding. Mirrors sema_expr.asm's
; field-lookup scan pattern (same linear-scan-over-AST_FIELD_DECL shape),
; reused as a pattern only, not as shared code (different return value:
; a byte offset, not a type pointer).

%include "config.inc"
%include "tokens.inc"
%include "ast.inc"
%include "symtab.inc"
%include "runtime.inc"

extern parser_src_buf
extern lookup_struct
extern bytes_equal

global type_size
global is_signed_type
global struct_size
global field_offset
global field_type
global is_scalar_loadable_type

section .data
; indexed by (TOK_KW_INT8 .. TOK_KW_UINT64) - TOK_KW_INT8, ld. tokens.inc's
; contiguous 22..31 range: int8,int16,int,int32,int64,uint8,uint16,uint,
; uint32,uint64.
int_type_sizes:
    dq 1, 2, 2, 4, 8, 1, 2, 2, 4, 8

section .text

; ===========================================================================
; type_size: in rdi = AST_TY_* node ptr. out: rax = size in bytes.
; ===========================================================================
type_size:
    push    rbx
    mov     rbx, rdi
    mov     rax, [rbx + AST_KIND_OFF]
    cmp     rax, AST_TY_POINTER
    je      .pointer
    cmp     rax, AST_TY_ARRAY
    je      .array
    ; AST_TY_BASE
    mov     rax, [rbx + AST_A_OFF]      ; builtin tag, 0 = struct-name ref
    cmp     rax, 0
    jne     .builtin
    mov     rdi, [rbx + AST_B_OFF]      ; name_offset
    mov     rsi, [rbx + AST_C_OFF]      ; name_len
    call    lookup_struct
    mov     rax, [rax + STE_DECL_PTR]
    mov     rdi, rax
    call    struct_size
    jmp     .done
.builtin:
    cmp     rax, TOK_KW_BOOL
    je      .size1
    ; int8..uint64 range
    sub     rax, TOK_KW_INT8
    lea     rcx, [int_type_sizes]
    mov     rax, [rcx + rax*8]
    jmp     .done
.size1:
    mov     rax, 1
    jmp     .done
.pointer:
    mov     rax, 8
    jmp     .done
.array:
    mov     rdi, [rbx + AST_A_OFF]      ; element type
    call    type_size
    mov     rcx, [rbx + AST_B_OFF]      ; element count
    imul    rax, rcx
.done:
    pop     rbx
    ret

; ===========================================================================
; is_signed_type: in rdi = AST_TY_* node ptr. out: rax = 1/0. Only
; meaningful for builtin integer BASE types (int8..int64) -- everything
; else (bool, pointer, array, struct) is 0, which is also the correct
; "zero-extend on load" answer for bool.
; ===========================================================================
is_signed_type:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_TY_BASE
    jne     .no
    mov     rax, [rdi + AST_A_OFF]
    cmp     rax, TOK_KW_INT8
    jl      .no
    cmp     rax, TOK_KW_INT64
    jg      .no
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

; ===========================================================================
; struct_size: in rdi = AST_STRUCT_DECL ptr. out: rax = packed sum of every
; field's size, declaration order.
; ===========================================================================
struct_size:
    push    rbx
    push    r12
    push    r13
    push    r14
    mov     rbx, rdi
    mov     r12, [rbx + AST_C_OFF]      ; fields ptr
    mov     r13, [rbx + AST_D_OFF]      ; field_count
    xor     r14, r14                    ; running total
    xor     rcx, rcx                    ; index
.loop:
    cmp     rcx, r13
    jae     .done
    push    rcx
    mov     rax, [r12 + rcx*8]          ; AST_FIELD_DECL ptr
    mov     rdi, [rax + AST_C_OFF]      ; field type
    call    type_size
    add     r14, rax
    pop     rcx
    inc     rcx
    jmp     .loop
.done:
    mov     rax, r14
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; field_offset: in rdi = AST_STRUCT_DECL ptr, rsi = field name_offset,
; rdx = field name_len. out: rax = byte offset of that field (packed --
; running sum of every preceding field's size). Assumes the field exists
; (already validated by the semantic checker before codegen ever runs).
; ===========================================================================
field_offset:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     rbx, rdi                    ; struct decl
    mov     r12, rsi                    ; query name_offset
    mov     r13, rdx                    ; query name_len
    mov     r14, [rbx + AST_C_OFF]      ; fields ptr
    mov     r9, [rbx + AST_D_OFF]       ; field_count
    xor     r15, r15                    ; running offset
    xor     rcx, rcx                    ; index
.loop:
    cmp     rcx, r9
    jae     .not_found
    mov     rax, [r14 + rcx*8]          ; AST_FIELD_DECL ptr
    cmp     qword [rax + AST_B_OFF], r13
    jne     .next
    push    rax
    push    rcx
    push    r9                          ; field_count -- no callee is
                                         ; trusted to leave any register
                                         ; untouched across a call in this
                                         ; codebase, not even r8-r15
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, r12
    mov     rdx, r13
    call    bytes_equal
    mov     r8, rax                     ; match result -- must survive the
                                         ; pops below, which restore rax to
                                         ; the field_decl ptr, not the
                                         ; comparison result
    pop     r9
    pop     rcx
    pop     rax
    cmp     r8, 0
    jne     .found
.next:
    push    rax
    push    rcx                         ; type_size's builtin-size lookup
                                         ; uses rcx as its own scratch
                                         ; (lea rcx, [int_type_sizes]) --
                                         ; must protect our loop index
                                         ; across the call
    push    r9                          ; field_count -- same "never trust
                                         ; a register across a call" rule
    mov     rdi, [rax + AST_C_OFF]
    call    type_size
    add     r15, rax
    pop     r9
    pop     rcx
    pop     rax
    inc     rcx
    jmp     .loop
.found:
    mov     rax, r15
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret
.not_found:
    ; defensive only -- callers only ever invoke field_offset for a name
    ; already validated to exist on this struct by the semantic checker
    xor     rax, rax
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; field_type: in rdi = AST_STRUCT_DECL ptr, rsi = field name_offset,
; rdx = field name_len. out: rax = that field's declared type node ptr.
; Same linear-scan shape as field_offset (duplicated, not shared, per
; this codebase's small-helper convention) but returns the field's own
; declared type instead of its accumulated packed offset -- needed by
; gen_lvalue's FIELD case (codegen_expr.asm) for the result type,
; separately from field_offset's address-arithmetic use there.
; ===========================================================================
field_type:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi                    ; struct decl
    mov     r12, rsi                    ; query name_offset
    mov     r13, rdx                    ; query name_len
    mov     r9, [rbx + AST_D_OFF]       ; field_count
    mov     r8, [rbx + AST_C_OFF]       ; fields ptr
    xor     rcx, rcx
.loop:
    cmp     rcx, r9
    jae     .not_found
    mov     rax, [r8 + rcx*8]
    cmp     qword [rax + AST_B_OFF], r13
    jne     .next
    push    rax
    push    rcx
    push    r9                          ; field_count
    push    r8                          ; fields ptr -- no callee is
                                         ; trusted to leave any register
                                         ; untouched across a call here,
                                         ; not even r8-r15
    mov     rdi, [parser_src_buf]
    add     rdi, [rax + AST_A_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, r12
    mov     rdx, r13
    call    bytes_equal
    mov     r10, rax
    pop     r8
    pop     r9
    pop     rcx
    pop     rax
    cmp     r10, 0
    jne     .found
.next:
    inc     rcx
    jmp     .loop
.found:
    mov     rax, [rax + AST_C_OFF]      ; field's declared type
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
; is_scalar_loadable_type: in rdi = AST_TY_* node ptr. out: rax = 1/0 --
; true iff this type legitimately fits in a single 8-byte register (a
; builtin base type, or a pointer). False for a struct-name reference or
; AST_TY_ARRAY. Phase 2 onward: decls/params may be ANY type (composite
; included, ld. codegen_composite.asm) -- this narrower guard is used
; only at the specific points a value would otherwise be funneled
; through rax as if it were scalar (gen_rvalue's IDENT/INDEX/FIELD/
; UNARY(*) load path, BINARY operands, user-function CALL arguments and
; composite-returning RETURN expressions), not at decl/param declaration
; time itself.
; ===========================================================================
is_scalar_loadable_type:
    mov     rax, [rdi + AST_KIND_OFF]
    cmp     rax, AST_TY_POINTER
    je      .yes
    cmp     rax, AST_TY_BASE
    jne     .no
    cmp     qword [rdi + AST_A_OFF], 0  ; 0 = struct-name reference
    je      .no
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret
