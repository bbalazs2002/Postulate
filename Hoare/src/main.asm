; Postulate Stage 0 -- lexer driver.
;
; Owns every syscall and all diagnostic formatting (lexer.asm performs none
; of either -- see docs/postulate_stage0_lexer_spec.md section 3). Reads all
; of stdin, repeatedly calls lex_next, and either dumps a text token stream
; to stdout (section 9) or reports a lexical error to stderr and exits
; non-zero (section 7).
;
; Internal calling convention: System V AMD64 caller/callee-saved register
; split (spec section 5). Every routine below documents which callee-saved
; registers it uses.
;
; _start is the process entry point (not reached via `call`), so there is no
; return address on the stack; the kernel guarantees rsp is 16-byte aligned
; at entry per the SysV ABI, and _start pushes nothing before its first
; `call`, so the calls below already satisfy the "rsp % 16 == 0 at call"
; convention with no extra alignment code needed.

%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern lex_next
global _start

section .bss
tok:            resb TOKEN_SIZE
char_scratch:   resb 1
scratch_line:   resq 1
scratch_col:    resq 1
scratch_offset: resq 1

section .data
str_IDENT:     db "IDENT "
str_IDENT_len  equ $ - str_IDENT
str_KW:        db "KW "
str_KW_len     equ $ - str_KW
str_INT:       db "INT "
str_INT_len    equ $ - str_INT
str_OP:        db "OP "
str_OP_len     equ $ - str_OP
str_EOF:       db "EOF"
str_EOF_len    equ $ - str_EOF
nl:            db 10

lbl_colon:        db "COLON"
lbl_colon_len     equ $ - lbl_colon
lbl_semi:         db "SEMI"
lbl_semi_len      equ $ - lbl_semi
lbl_comma:        db "COMMA"
lbl_comma_len     equ $ - lbl_comma
lbl_dot:          db "DOT"
lbl_dot_len       equ $ - lbl_dot
lbl_lparen:       db "LPAREN"
lbl_lparen_len    equ $ - lbl_lparen
lbl_rparen:       db "RPAREN"
lbl_rparen_len    equ $ - lbl_rparen
lbl_lbrace:       db "LBRACE"
lbl_lbrace_len    equ $ - lbl_lbrace
lbl_rbrace:       db "RBRACE"
lbl_rbrace_len    equ $ - lbl_rbrace
lbl_lbracket:     db "LBRACKET"
lbl_lbracket_len  equ $ - lbl_lbracket
lbl_rbracket:     db "RBRACKET"
lbl_rbracket_len  equ $ - lbl_rbracket

; indexed by (kind - TOK_COLON), i.e. 0..9, matching TOK_COLON..TOK_RBRACKET order
punct_labels:
    dq lbl_colon,    lbl_colon_len
    dq lbl_semi,     lbl_semi_len
    dq lbl_comma,    lbl_comma_len
    dq lbl_dot,      lbl_dot_len
    dq lbl_lparen,   lbl_lparen_len
    dq lbl_rparen,   lbl_rparen_len
    dq lbl_lbrace,   lbl_lbrace_len
    dq lbl_rbrace,   lbl_rbrace_len
    dq lbl_lbracket, lbl_lbracket_len
    dq lbl_rbracket, lbl_rbracket_len

msg_err_unexpected_1:     db "lex error: unexpected character '"
msg_err_unexpected_1_len  equ $ - msg_err_unexpected_1
msg_err_unexpected_2:     db "' (0x"
msg_err_unexpected_2_len  equ $ - msg_err_unexpected_2
msg_err_unexpected_3:     db ") at line "
msg_err_unexpected_3_len  equ $ - msg_err_unexpected_3
msg_err_col:               db ", col "
msg_err_col_len            equ $ - msg_err_col
msg_err_offset:             db " (byte offset "
msg_err_offset_len          equ $ - msg_err_offset
msg_err_close:                db ")", 10
msg_err_close_len             equ $ - msg_err_close
msg_err_comment_1:         db "lex error: unterminated block comment starting at line "
msg_err_comment_1_len      equ $ - msg_err_comment_1
msg_err_based_form_empty:   db "lex error: based-form integer literal has no digits after 'n' at line "
msg_err_based_form_empty_len equ $ - msg_err_based_form_empty

section .text

; ===========================================================================
; _start: read all of stdin, then repeatedly tokenize and dump to stdout.
; ===========================================================================
_start:
    mov     rdi, src_buf
    mov     rsi, SRC_BUF_SIZE
    call    read_all
    mov     [src_len], rax

    xor     rbx, rbx             ; cursor = 0
.token_loop:
    mov     rdi, src_buf
    mov     rsi, rbx
    mov     rdx, [src_len]
    mov     rcx, tok
    call    lex_next
    mov     rbx, rax             ; advance cursor

    mov     rax, [tok + TOK_KIND_OFF]
    cmp     rax, TOK_EOF
    je      .on_eof
    cmp     rax, TOK_ERROR
    je      .on_error
    cmp     rax, TOK_ERROR_COMMENT
    je      .on_error_comment

    call    format_and_emit_token
    jmp     .token_loop

.on_eof:
    mov     rsi, str_EOF
    mov     rdx, str_EOF_len
    call    emit_str
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    call    flush_out
    mov     rax, 60
    xor     rdi, rdi
    syscall

.on_error:
    call    flush_out            ; the already-lexed prefix is still useful output
    call    report_error         ; never returns

.on_error_comment:
    call    flush_out
    call    report_error_comment ; never returns

; ===========================================================================
; format_and_emit_token: formats [tok] per its kind, appends to out_buf plus
; a trailing newline (spec section 9). Identifiers/keywords/int-literals/
; operators all echo their exact source span (offset/length already point at
; it -- no separate spelling table needed); structural punctuation prints a
; bare label with no span.
; ===========================================================================
format_and_emit_token:
    mov     rax, [tok + TOK_KIND_OFF]

    cmp     rax, TOK_IDENT
    jne     .not_ident
    mov     rsi, str_IDENT
    mov     rdx, str_IDENT_len
    call    emit_str
    jmp     .emit_span
.not_ident:
    cmp     rax, TOK_INT
    jne     .not_int
    mov     rsi, str_INT
    mov     rdx, str_INT_len
    call    emit_str
    jmp     .emit_span
.not_int:
    cmp     rax, TOK_KW_FUNCTION
    jl      .not_kw
    cmp     rax, TOK_KW_VOID
    jg      .not_kw
    mov     rsi, str_KW
    mov     rdx, str_KW_len
    call    emit_str
    jmp     .emit_span
.not_kw:
    cmp     rax, TOK_ASSIGN
    jl      .not_op
    cmp     rax, TOK_PIPE
    jg      .not_op
    mov     rsi, str_OP
    mov     rdx, str_OP_len
    call    emit_str
    jmp     .emit_span
.not_op:
    cmp     rax, TOK_COLON
    jl      .newline
    cmp     rax, TOK_RBRACKET
    jg      .newline
    mov     rcx, rax
    sub     rcx, TOK_COLON
    shl     rcx, 4              ; byte offset = index * 16 (scale factors only allow 1/2/4/8)
    mov     rsi, [punct_labels + rcx]
    mov     rdx, [punct_labels + rcx + 8]
    call    emit_str
    jmp     .newline
.emit_span:
    mov     rax, [tok + TOK_OFFSET_OFF]
    lea     rsi, [src_buf + rax]
    mov     rdx, [tok + TOK_LENGTH_OFF]
    call    emit_str
.newline:
    mov     rsi, nl
    mov     rdx, 1
    call    emit_str
    ret

; ===========================================================================
; report_error / report_error_comment: build a diagnostic in err_buf, write
; it to stderr, exit(1). Neither returns.
; ===========================================================================
report_error:
    mov     qword [err_cursor], 0
    mov     rax, [tok + TOK_OFFSET_OFF]
    mov     [scratch_offset], rax
    mov     rdi, rax
    call    compute_line_col
    mov     [scratch_line], rax
    mov     [scratch_col], rdx

    ; lexer.asm has two TOK_ERROR producers that point at a real offending
    ; byte (a bare '=', or any other unrecognized character) -- both set
    ; TOK_LENGTH_OFF = 1 -- and a third (an empty based-form digit run,
    ; e.g. "16n" with nothing after the 'n') that sets TOK_LENGTH_OFF = 0
    ; and points OFFSET at whatever byte happens to follow the 'n', which
    ; is not itself invalid. Showing "unexpected character 'X'" for that
    ; third case would blame an innocent, unrelated byte (or read one past
    ; the source if 'n' was the last byte in the file); report the real
    ; problem by length instead.
    mov     rax, [tok + TOK_LENGTH_OFF]
    cmp     rax, 0
    jne     .has_span

    mov     rsi, msg_err_based_form_empty
    mov     rdx, msg_err_based_form_empty_len
    call    err_append_str
    jmp     .common

.has_span:
    mov     rsi, msg_err_unexpected_1
    mov     rdx, msg_err_unexpected_1_len
    call    err_append_str

    mov     rax, [scratch_offset]
    movzx   eax, byte [src_buf + rax]
    mov     [char_scratch], al
    mov     rsi, char_scratch
    mov     rdx, 1
    call    err_append_str

    mov     rsi, msg_err_unexpected_2
    mov     rdx, msg_err_unexpected_2_len
    call    err_append_str

    mov     rax, [scratch_offset]
    movzx   eax, byte [src_buf + rax]
    call    err_append_hex_byte

    mov     rsi, msg_err_unexpected_3
    mov     rdx, msg_err_unexpected_3_len
    call    err_append_str

.common:
    mov     rax, [scratch_line]
    call    err_append_dec

    mov     rsi, msg_err_col
    mov     rdx, msg_err_col_len
    call    err_append_str

    mov     rax, [scratch_col]
    call    err_append_dec

    mov     rsi, msg_err_offset
    mov     rdx, msg_err_offset_len
    call    err_append_str

    mov     rax, [scratch_offset]
    call    err_append_dec

    mov     rsi, msg_err_close
    mov     rdx, msg_err_close_len
    call    err_append_str

    mov     rdi, 2
    mov     rsi, err_buf
    mov     rdx, [err_cursor]
    call    write_all

    mov     rax, 60
    mov     rdi, 1
    syscall

report_error_comment:
    mov     qword [err_cursor], 0
    mov     rax, [tok + TOK_OFFSET_OFF]
    mov     [scratch_offset], rax
    mov     rdi, rax
    call    compute_line_col
    mov     [scratch_line], rax
    mov     [scratch_col], rdx

    mov     rsi, msg_err_comment_1
    mov     rdx, msg_err_comment_1_len
    call    err_append_str

    mov     rax, [scratch_line]
    call    err_append_dec

    mov     rsi, msg_err_col
    mov     rdx, msg_err_col_len
    call    err_append_str

    mov     rax, [scratch_col]
    call    err_append_dec

    mov     rsi, msg_err_offset
    mov     rdx, msg_err_offset_len
    call    err_append_str

    mov     rax, [scratch_offset]
    call    err_append_dec

    mov     rsi, msg_err_close
    mov     rdx, msg_err_close_len
    call    err_append_str

    mov     rdi, 2
    mov     rsi, err_buf
    mov     rdx, [err_cursor]
    call    write_all

    mov     rax, 60
    mov     rdi, 1
    syscall
