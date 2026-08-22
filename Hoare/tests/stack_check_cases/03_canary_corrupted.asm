; Sanity fixture proving the per-function stack-canary check actually
; fires. Identical to 01_clean_ok.asm except for one injected bug: pf_main
; overwrites its own canary slot [rbp - 8] after planting it -- simulating
; an out-of-bounds local array/struct write reaching past its own slot
; into the canary (Stage 0 has no bounds checking for a dynamic/computed
; array index, see docs/postulate_v0_language_reference.md section 10).
; The overall rsp is untouched (mov rsp, rbp in the epilogue still
; produces a balanced final rsp), so this isolates the canary check from
; the balance check: only the canary check should fire here. Must exit
; 112.
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

    mov     qword [rbp - 8], 0      ; INJECTED BUG: out-of-bounds write
                                     ; smashes the canary slot
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
