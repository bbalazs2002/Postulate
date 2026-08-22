; Postulate Stage 0 -- code generator driver entry point.
;
; Same shape as checker_main.asm: parse the entire stdin as a `program`,
; no directive line. Unlike build/checker, generated code is only ever
; emitted for a program that has already passed check_program in full --
; codegen never runs on unchecked input, see docs/postulate_stage0_
; codegen_spec.md.

%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern parser_init
extern parser_expect
extern parse_program
extern check_program
extern gen_program

global _start

section .data
msg_expected_eof:    db "expected end of input"
msg_expected_eof_len equ $ - msg_expected_eof

section .text

_start:
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
