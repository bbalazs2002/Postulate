; Sanity fixture for scripts/run_stack_check_tests.sh: hand-written NASM
; matching the exact shape gen_program/gen_function emit when
; POSTULATE_STACK_CHECK=1 (see codegen_program.asm's s_header_checked/
; s_canary_write/s_epilogue_checked), with no injected bug. Proves the
; instrumentation itself doesn't false-positive on a correct program --
; must exit 0, the same as an uninstrumented equivalent would.
BITS 64
section .bss
__pf_entry_rsp: resq 1
section .data
__pf_msg_imbalance: db 'runtime error: stack pointer imbalance detected at program exit', 10
__pf_msg_imbalance_len equ $ - __pf_msg_imbalance
__pf_msg_canary: db 'runtime error: stack canary corrupted -- out-of-bounds local write', 10
__pf_msg_canary_len equ $ - __pf_msg_canary
section .text
global _start

__pf_stack_check_fail:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, r8
    mov     rdx, r9
    syscall
    mov     rax, 60
    mov     rdi, r10
    syscall

_start:
    mov     [__pf_entry_rsp], rsp
    call    pf_main
    mov     rcx, rsp
    cmp     rcx, [__pf_entry_rsp]
    je      .balance_ok
    mov     r8, __pf_msg_imbalance
    mov     r9, __pf_msg_imbalance_len
    mov     r10, 113
    jmp     __pf_stack_check_fail
.balance_ok:
    mov     rdi, rax
    mov     rax, 60
    syscall

pf_main:
    push    rbp
    mov     rbp, rsp
    sub     rsp, 16
    mov     rax, 0x5CA1AB1E5CA1AB1E
    mov     qword [rbp - 8], rax

    mov     rax, 0

.epilogue:
    push    rax
    push    rcx
    mov     rax, [rbp - 8]
    mov     rcx, 0x5CA1AB1E5CA1AB1E
    cmp     rax, rcx
    jne     .canary_bad
    pop     rcx
    pop     rax
    mov     rsp, rbp
    pop     rbp
    ret
.canary_bad:
    pop     rcx
    pop     rax
    mov     r8, __pf_msg_canary
    mov     r9, __pf_msg_canary_len
    mov     r10, 112
    jmp     __pf_stack_check_fail
