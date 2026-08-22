; Postulate Stage 0 -- semantic checker driver entry point.
;
; Unlike parser_main.asm's test-driver (directive-prefixed snippet -> one
; grammar rule), build/checker always does exactly one thing: parse the
; entire stdin as a `program` and semantically check it. No directive
; line -- this is the shape a real "compile this .ptl file" invocation
; takes, closest of anything built so far to the eventual `hoare` CLI.
; See docs/postulate_stage0_semantics_spec.md.

%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern parser_init
extern parser_expect
extern parse_program
extern check_program

global _start

section .data
msg_expected_eof:    db "expected end of input"
msg_expected_eof_len equ $ - msg_expected_eof
msg_ok: db "OK", 10
msg_ok_len equ $ - msg_ok

section .text

_start:
    mov     rdi, src_buf
    mov     rsi, SRC_BUF_SIZE
    call    read_all
    mov     r12, rax                    ; total length

    mov     rdi, src_buf
    xor     rsi, rsi                    ; start offset 0 -- no directive
                                         ; line to skip past, unlike the
                                         ; parser_cases/blackbox test driver
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

    mov     rsi, msg_ok
    mov     rdx, msg_ok_len
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall
