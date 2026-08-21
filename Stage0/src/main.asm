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

extern lex_next
global _start

section .bss
src_buf:        resb SRC_BUF_SIZE
scratch_byte:   resb 1              ; read_all: disambiguates exact-fit vs overflow
src_len:        resq 1
tok:            resb TOKEN_SIZE
out_buf:        resb OUT_BUF_SIZE
out_cursor:     resq 1
err_buf:        resb 512
err_cursor:     resq 1
char_scratch:   resb 1
scratch_line:   resq 1
scratch_col:    resq 1
scratch_offset: resq 1

section .data
msg_buf_full:      db "stage0: input exceeds fixed source buffer", 10
msg_buf_full_len   equ $ - msg_buf_full
msg_read_fail:     db "stage0: read() failed", 10
msg_read_fail_len  equ $ - msg_read_fail
msg_write_fail:    db "stage0: write() failed", 10
msg_write_fail_len equ $ - msg_write_fail

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
; read_all: fills [rdi .. rdi+rsi) from stdin until EOF or capacity reached.
; in:  rdi = buffer pointer, rsi = buffer capacity
; out: rax = total bytes read
; Never returns on a fatal error -- writes a diagnostic to stderr and exits
; with code 2.
; callee-saved used: rbx (buffer base), r12 (capacity), r13 (total so far)
; ===========================================================================
read_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    xor     r13, r13
.read_loop:
    mov     rdx, r12
    sub     rdx, r13
    jz      .maybe_full
    mov     rax, 0
    xor     rdi, rdi
    lea     rsi, [rbx + r13]
    syscall
    cmp     rax, 0
    jl      .read_error
    je      .done
    add     r13, rax
    jmp     .read_loop
.maybe_full:
    mov     rax, 0
    xor     rdi, rdi
    mov     rsi, scratch_byte
    mov     rdx, 1
    syscall
    cmp     rax, 0
    jl      .read_error
    je      .done               ; peek read 0 bytes -> true EOF, exact fit is fine
.buffer_full:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_buf_full
    mov     rdx, msg_buf_full_len
    syscall
    mov     rax, 60
    mov     rdi, 2
    syscall
.read_error:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_read_fail
    mov     rdx, msg_read_fail_len
    syscall
    mov     rax, 60
    mov     rdi, 2
    syscall
.done:
    mov     rax, r13
    pop     r13
    pop     r12
    pop     rbx
    ret

; ===========================================================================
; write_all: writes [rsi .. rsi+rdx) to fd rdi, retrying on partial writes.
; Never returns on a fatal error -- writes a diagnostic to stderr and exits
; with code 2.
; callee-saved used: rbx (fd), r12 (buf cursor), r13 (bytes remaining)
; ===========================================================================
write_all:
    push    rbx
    push    r12
    push    r13
    mov     rbx, rdi
    mov     r12, rsi
    mov     r13, rdx
.write_loop:
    cmp     r13, 0
    je      .done
    mov     rax, 1
    mov     rdi, rbx
    mov     rsi, r12
    mov     rdx, r13
    syscall
    cmp     rax, 0
    jle     .write_error
    add     r12, rax
    sub     r13, rax
    jmp     .write_loop
.write_error:
    mov     rax, 1
    mov     rdi, 2
    mov     rsi, msg_write_fail
    mov     rdx, msg_write_fail_len
    syscall
    mov     rax, 60
    mov     rdi, 2
    syscall
.done:
    pop     r13
    pop     r12
    pop     rbx
    ret

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
; emit_str / flush_out: buffered stdout writer for the token dump.
; emit_str in: rsi = ptr, rdx = len. callee-saved used: rbx, r12.
; ===========================================================================
emit_str:
    push    rbx
    push    r12
    mov     rbx, rsi
    mov     r12, rdx
    cmp     r12, OUT_BUF_SIZE
    ja      .too_big
    mov     rax, [out_cursor]
    add     rax, r12
    cmp     rax, OUT_BUF_SIZE
    jbe     .no_flush
    call    flush_out
.no_flush:
    mov     rax, [out_cursor]
    lea     rdi, [out_buf + rax]
    mov     rcx, r12
    mov     rsi, rbx
.copy_loop:
    cmp     rcx, 0
    je      .copy_done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .copy_loop
.copy_done:
    add     [out_cursor], r12
    pop     r12
    pop     rbx
    ret
.too_big:
    ; a single token's formatted span exceeds the entire output buffer --
    ; unrecoverable for this fixed-buffer design (never hit by realistic
    ; Stage 1 sources; treated as an I/O-class failure)
    mov     rax, 60
    mov     rdi, 2
    syscall

flush_out:
    mov     rdx, [out_cursor]
    cmp     rdx, 0
    je      .nothing
    mov     rdi, 1
    mov     rsi, out_buf
    call    write_all
    mov     qword [out_cursor], 0
.nothing:
    ret

; ===========================================================================
; compute_line_col: in rdi = byte offset; out rax = line (1-based),
; rdx = col (1-based). One-time backward-style scan, only ever called on the
; error path (spec section 7) -- lex_next itself never tracks line/col.
; callee-saved used: rbx (scan index), r12 (start-of-current-line offset).
; ===========================================================================
compute_line_col:
    push    rbx
    push    r12
    xor     rax, rax            ; newline count
    xor     r12, r12            ; offset of the start of the current line
    xor     rbx, rbx            ; scan index
.scan_loop:
    cmp     rbx, rdi
    jae     .done
    cmp     byte [src_buf + rbx], 10
    jne     .next
    inc     rax
    lea     r12, [rbx + 1]
.next:
    inc     rbx
    jmp     .scan_loop
.done:
    inc     rax                 ; line = newline_count + 1
    mov     rdx, rdi
    sub     rdx, r12
    inc     rdx                 ; 1-based column
    pop     r12
    pop     rbx
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

; ===========================================================================
; err_append_str / err_append_dec / err_append_hex_byte: unbuffered (single
; write at the end) formatting helpers for the one-shot diagnostic message.
; err_buf is generously sized (512 bytes) relative to one diagnostic line, so
; unlike emit_str these never need a flush-on-overflow path.
; ===========================================================================
err_append_str:
    push    rbx
    push    r12
    mov     rbx, rsi
    mov     r12, rdx
    mov     rax, [err_cursor]
    lea     rdi, [err_buf + rax]
    mov     rcx, r12
    mov     rsi, rbx
.copy:
    cmp     rcx, 0
    je      .done
    mov     al, [rsi]
    mov     [rdi], al
    inc     rsi
    inc     rdi
    dec     rcx
    jmp     .copy
.done:
    add     [err_cursor], r12
    pop     r12
    pop     rbx
    ret

; in: rax = unsigned value
err_append_dec:
    push    rbx
    push    r12
    push    r13
    sub     rsp, 32
    mov     rbx, rsp
    lea     r12, [rbx + 32]
    mov     r13, rax
    test    r13, r13
    jnz     .loop
    dec     r12
    mov     byte [r12], '0'
    jmp     .emit
.loop:
    test    r13, r13
    jz      .emit
    xor     rdx, rdx
    mov     rax, r13
    mov     rcx, 10
    div     rcx
    add     dl, '0'
    dec     r12
    mov     [r12], dl
    mov     r13, rax
    jmp     .loop
.emit:
    mov     rsi, r12
    lea     rdx, [rbx + 32]
    sub     rdx, r12
    call    err_append_str
    add     rsp, 32
    pop     r13
    pop     r12
    pop     rbx
    ret

; in: al = byte value; appends two uppercase hex digits
err_append_hex_byte:
    push    rbx
    sub     rsp, 16
    mov     bl, al
    shr     al, 4
    and     al, 0x0F
    cmp     al, 10
    jl      .h1_digit
    add     al, 'A' - 10
    jmp     .h1_done
.h1_digit:
    add     al, '0'
.h1_done:
    mov     [rsp], al
    mov     al, bl
    and     al, 0x0F
    cmp     al, 10
    jl      .h2_digit
    add     al, 'A' - 10
    jmp     .h2_done
.h2_digit:
    add     al, '0'
.h2_done:
    mov     [rsp + 1], al
    mov     rsi, rsp
    mov     rdx, 2
    call    err_append_str
    add     rsp, 16
    pop     rbx
    ret
