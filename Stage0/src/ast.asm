; Postulate Stage 0 -- AST node arena (bump allocator).
;
; No dynamic memory allocation anywhere in this codebase (matches the target
; language's own no-GC/no-hidden-allocation design) -- AST nodes live in a
; fixed-size arena, bump-allocated, never individually freed. See
; docs/postulate_stage0_parser_spec.md section 4.3.

%include "config.inc"
%include "ast.inc"

global ast_alloc_node
global ast_alloc_bytes
global ast_build_unary
global ast_build_binary

section .bss
ast_arena:  resb AST_ARENA_SIZE
ast_cursor: resq 1

section .data
msg_arena_full:     db "stage0: AST arena exhausted", 10
msg_arena_full_len  equ $ - msg_arena_full

section .text

; ===========================================================================
; ast_alloc_node: bump-allocates one 40-byte node and stamps its kind.
; in:  rdi = kind constant
; out: rax = pointer to the new node ([rax+AST_KIND_OFF] already set;
;      a/b/c/d are zero-filled, courtesy of .bss, until the caller sets them)
; Never returns on arena exhaustion -- stderr diagnostic, exit(2).
; ===========================================================================
ast_alloc_node:
    mov     rax, [ast_cursor]
    add     rax, AST_NODE_SIZE
    cmp     rax, AST_ARENA_SIZE
    ja      .exhausted
    mov     rax, [ast_cursor]
    add     qword [ast_cursor], AST_NODE_SIZE
    lea     rax, [ast_arena + rax]
    mov     [rax + AST_KIND_OFF], rdi
    ret
.exhausted:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_arena_full
    mov     rdx, msg_arena_full_len
    syscall
    mov     rax, 60
    mov     rdi, 2
    syscall

; ===========================================================================
; ast_alloc_bytes: bump-allocates a raw byte span (used for the exact-size
; node-pointer arrays backing variable-arity lists, spec section 8).
; in:  rdi = byte count
; out: rax = pointer
; Never returns on arena exhaustion -- same path as ast_alloc_node.
; ===========================================================================
ast_alloc_bytes:
    mov     rax, [ast_cursor]
    add     rax, rdi
    cmp     rax, AST_ARENA_SIZE
    ja      ast_alloc_node.exhausted
    mov     rax, [ast_cursor]
    add     [ast_cursor], rdi
    lea     rax, [ast_arena + rax]
    ret

; ===========================================================================
; ast_build_unary: in rdi = op kind, rsi = operand node ptr; out rax = node
; ===========================================================================
ast_build_unary:
    push    rbx
    push    r12
    mov     rbx, rdi
    mov     r12, rsi
    mov     rdi, AST_EX_UNARY
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], rbx
    mov     [rax + AST_B_OFF], r12
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; ast_build_binary: in rdi = op kind, rsi = left ptr, rdx = right ptr;
; out rax = node
; ===========================================================================
ast_build_binary:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
    mov     rdi, AST_EX_BINARY
    call    ast_alloc_node
    mov     [rax + AST_A_OFF], rbx
    mov     [rax + AST_B_OFF], r12
    mov     [rax + AST_C_OFF], r13
    pop     r13
    pop     r12
    pop     rbx
    ret
