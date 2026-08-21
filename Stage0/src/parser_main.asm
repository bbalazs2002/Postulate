; Postulate Stage 0 -- parser test-driver entry point.
;
; Reads all of stdin (reusing runtime.asm's read_all / src_buf), strips a
; one-line directive ("TYPE" or "EXPR") that selects which grammar rule to
; exercise on the remainder, parses it, and dumps the resulting AST as an
; S-expression to stdout -- or reports a syntax error to stderr and exits 1.
; See docs/postulate_stage0_parser_spec.md section 12.
;
%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern parser_init
extern parser_expect
extern parse_type
extern parse_expr
extern dump_type
extern dump_expr

global _start

section .data
str_TYPE: db "TYPE"
str_EXPR: db "EXPR"
msg_expected_eof:    db "expected end of input"
msg_expected_eof_len equ $ - msg_expected_eof
nl: db 10

section .text

_start:
    mov     rdi, src_buf
    mov     rsi, SRC_BUF_SIZE
    call    read_all
    mov     r12, rax             ; total length

    ; find the first '\n' -- the directive line's terminator
    xor     rbx, rbx
.scan_nl:
    cmp     rbx, r12
    jae     .bad_directive
    cmp     byte [src_buf + rbx], 10
    je      .found_nl
    inc     rbx
    jmp     .scan_nl
.found_nl:
    cmp     rbx, 4
    jne     .bad_directive

    mov     rsi, src_buf
    mov     rdi, str_TYPE
    call    bytes_equal4
    cmp     rax, 1
    je      .is_type

    mov     rsi, src_buf
    mov     rdi, str_EXPR
    call    bytes_equal4
    cmp     rax, 1
    je      .is_expr

.bad_directive:
    ; malformed test-harness input (missing/unknown directive line) -- a
    ; harness-usage error, not a language syntax error
    mov     rax, 60
    mov     rdi, 2
    syscall

.is_type:
    lea     rsi, [rbx + 1]        ; parse starts right after the '\n'
    mov     rdi, src_buf
    mov     rdx, r12
    call    parser_init
    call    parse_type
    mov     r13, rax              ; AST root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    dump_type
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall

.is_expr:
    lea     rsi, [rbx + 1]        ; parse starts right after the '\n'
    mov     rdi, src_buf
    mov     rdx, r12
    call    parser_init
    call    parse_expr
    mov     r13, rax              ; AST root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    dump_expr
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall

; bytes_equal4: in rsi = ptr1, rdi = ptr2 (compares 4 bytes); out rax = 1/0
bytes_equal4:
    mov     eax, [rsi]
    cmp     eax, [rdi]
    jne     .no
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret
