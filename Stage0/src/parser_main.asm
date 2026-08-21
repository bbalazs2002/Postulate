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
extern parse_stmt
extern parse_decl
extern parse_func_block
extern dump_type
extern dump_expr
extern dump_stmt
extern dump_decl
extern dump_func_block

global _start

section .data
str_TYPE: db "TYPE"
str_TYPE_len equ $ - str_TYPE
str_EXPR: db "EXPR"
str_EXPR_len equ $ - str_EXPR
str_STMT: db "STMT"
str_STMT_len equ $ - str_STMT
str_DECL: db "DECL"
str_DECL_len equ $ - str_DECL
str_FUNC_BLOCK: db "FUNC_BLOCK"
str_FUNC_BLOCK_len equ $ - str_FUNC_BLOCK
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
    ; rbx = directive-line length. Check each candidate's own length first
    ; (cheap short-circuit), only then compare bytes -- directive words are
    ; not all the same length (e.g. a future "FUNC_BLOCK" is 10 bytes).
    cmp     rbx, str_TYPE_len
    jne     .not_type
    mov     rdi, src_buf
    mov     rsi, str_TYPE
    mov     rdx, str_TYPE_len
    call    bytes_equal
    cmp     rax, 1
    je      .is_type
.not_type:
    cmp     rbx, str_EXPR_len
    jne     .not_expr
    mov     rdi, src_buf
    mov     rsi, str_EXPR
    mov     rdx, str_EXPR_len
    call    bytes_equal
    cmp     rax, 1
    je      .is_expr
.not_expr:
    cmp     rbx, str_STMT_len
    jne     .not_stmt
    mov     rdi, src_buf
    mov     rsi, str_STMT
    mov     rdx, str_STMT_len
    call    bytes_equal
    cmp     rax, 1
    je      .is_stmt
.not_stmt:
    cmp     rbx, str_DECL_len
    jne     .not_decl
    mov     rdi, src_buf
    mov     rsi, str_DECL
    mov     rdx, str_DECL_len
    call    bytes_equal
    cmp     rax, 1
    je      .is_decl
.not_decl:
    cmp     rbx, str_FUNC_BLOCK_len
    jne     .not_func_block
    mov     rdi, src_buf
    mov     rsi, str_FUNC_BLOCK
    mov     rdx, str_FUNC_BLOCK_len
    call    bytes_equal
    cmp     rax, 1
    je      .is_func_block
.not_func_block:

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

.is_stmt:
    lea     rsi, [rbx + 1]        ; parse starts right after the '\n'
    mov     rdi, src_buf
    mov     rdx, r12
    call    parser_init
    call    parse_stmt
    mov     r13, rax              ; AST root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    dump_stmt
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall

.is_decl:
    lea     rsi, [rbx + 1]        ; parse starts right after the '\n'
    mov     rdi, src_buf
    mov     rdx, r12
    call    parser_init
    call    parse_decl
    mov     r13, rax              ; AST root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    dump_decl
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall

.is_func_block:
    lea     rsi, [rbx + 1]        ; parse starts right after the '\n'
    mov     rdi, src_buf
    mov     rdx, r12
    call    parser_init
    call    parse_func_block
    mov     r13, rax              ; AST root

    mov     rdi, TOK_EOF
    mov     rsi, msg_expected_eof
    mov     rdx, msg_expected_eof_len
    call    parser_expect

    mov     rdi, r13
    call    dump_func_block
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out

    mov     rax, 60
    xor     rdi, rdi
    syscall

; bytes_equal: in rdi = ptr1, rsi = ptr2, rdx = len; out rax = 1/0
bytes_equal:
    xor     rcx, rcx
.loop:
    cmp     rcx, rdx
    jae     .yes
    mov     al, [rdi + rcx]
    cmp     al, [rsi + rcx]
    jne     .no
    inc     rcx
    jmp     .loop
.yes:
    mov     rax, 1
    ret
.no:
    xor     rax, rax
    ret
