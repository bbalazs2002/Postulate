; Postulate Stage 0 -- code generator driver entry point.
;
; Same shape as checker_main.asm: parse the entire stdin as a `program`,
; no directive line. Unlike build/checker, generated code is only ever
; emitted for a program that has already passed check_program in full --
; codegen never runs on unchecked input, see docs/postulate_stage0_
; codegen_spec.md.
;
; Debug-only opt-in instrumentation: if the process's environment carries
; POSTULATE_STACK_CHECK=1, `stack_check_enabled` (read by codegen_program
; .asm's gen_program/gen_function/compute_local_offsets) is set to 1, and
; the emitted assembly gets extra self-checking code -- a stack-balance
; check around _start's call to pf_main, and a stack canary planted/
; verified in every function's prologue/epilogue -- used only by the test
; suite (see scripts/run_codegen_tests.sh) to catch stack corruption in
; generated programs. With the env var unset (the default, and every
; normal `hoare`-compiled program), gen_program/gen_function's output is
; byte-for-byte identical to before this existed -- no hidden runtime
; cost for real programs, per this project's design principle.

%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern parser_init
extern parser_expect
extern parse_program
extern check_program
extern gen_program

global _start
global stack_check_enabled

section .bss
stack_check_enabled: resb 1

section .data
msg_expected_eof:    db "expected end of input"
msg_expected_eof_len equ $ - msg_expected_eof
s_env_stack_check_flag: db "POSTULATE_STACK_CHECK=1", 0

section .text

; ===========================================================================
; env_matches_stack_check_flag: in rdi = NUL-terminated C-string ptr (one
; envp[] entry). out: rax = 1 iff it's byte-for-byte "POSTULATE_STACK_
; CHECK=1" (including the terminating NUL -- so "...=10" does not match).
; ===========================================================================
env_matches_stack_check_flag:
    mov     rsi, s_env_stack_check_flag
.cmp_loop:
    mov     al, [rdi]
    mov     dl, [rsi]
    cmp     al, dl
    jne     .no
    test    al, al
    jz      .yes
    inc     rdi
    inc     rsi
    jmp     .cmp_loop
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret

_start:
    ; --- scan the initial process envp[] for POSTULATE_STACK_CHECK=1,
    ; before anything else touches rsp. [rsp] = argc, [rsp+8 ..] =
    ; argv[0..argc-1], then an 8-byte NULL, then envp[0..] up to its own
    ; NULL terminator -- envp[0] therefore sits at rsp + 8*argc + 16.
    mov     rax, [rsp]                   ; argc
    lea     rbx, [rsp + rax*8 + 16]      ; -> envp[0]
.env_scan:
    mov     rcx, [rbx]
    cmp     rcx, 0
    je      .env_done
    mov     rdi, rcx
    call    env_matches_stack_check_flag
    cmp     rax, 0
    je      .env_next
    mov     byte [stack_check_enabled], 1
    jmp     .env_done
.env_next:
    add     rbx, 8
    jmp     .env_scan
.env_done:

    mov     rdi, src_buf
    mov     rsi, SRC_BUF_SIZE
    call    read_all
    mov     r12, rax                    ; total length

    mov     rdi, src_buf
    xor     rsi, rsi
    mov     rdx, r12
    call    parser_init
    call    parse_program
    mov     r13, rax                    ; AST_PROGRAM root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    check_program                ; never returns on a semantic
                                          ; error (exit 3)

    mov     rdi, r13
    call    gen_program                  ; never returns on an
                                          ; unsupported-construct error
                                          ; (exit 4); otherwise emits the
                                          ; whole .asm text to stdout

    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall
