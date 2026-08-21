; Postulate Stage 0 -- parser token lookahead buffer.
;
; lex_next (lexer.asm) returns exactly one token per call, with an explicit
; caller-owned cursor. The parser needs to look one token past "current"
; without consuming it, in exactly two places (the pointer-array type
; disambiguation, and the struct-literal-vs-bare-identifier disambiguation
; in `primary`) -- see docs/postulate_stage0_parser_spec.md section 5. A
; 2-slot buffer (current + a memoized peek) is sufficient for both.
;
; Internal calling convention: System V AMD64 caller/callee-saved split,
; same as lexer.asm/main.asm/runtime.asm.

%include "config.inc"
%include "tokens.inc"
%include "runtime.inc"

extern lex_next

global tok_cur
global tok_peek
global parser_src_buf
global parser_init
global parser_advance
global parser_peek
global parser_expect
global report_parse_error

section .bss
tok_cur:         resb TOKEN_SIZE
tok_peek:        resb TOKEN_SIZE
tok_peek_valid:  resq 1
raw_cursor:      resq 1
parser_src_buf:  resq 1
parser_src_len:  resq 1
perr_msg_ptr:    resq 1
perr_msg_len:    resq 1
perr_line:       resq 1
perr_col:        resq 1
perr_offset:     resq 1

; Duplicated from main.asm's lexer-driver .data (deliberate -- build/parser
; does not link main.asm, only the pure lex_next engine from lexer.asm; see
; docs/postulate_stage0_parser_spec.md section 9 / the "3rd instance of the
; same small pattern" note). Kept in exact sync by inspection with main.asm
; whenever tokens.inc's kind ranges change.
section .data
str_IDENT: db "IDENT "
str_IDENT_len equ $ - str_IDENT
str_KW:    db "KW "
str_KW_len equ $ - str_KW
str_INT:   db "INT "
str_INT_len equ $ - str_INT
str_OP:    db "OP "
str_OP_len equ $ - str_OP
str_EOF:   db "EOF"
str_EOF_len equ $ - str_EOF

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

; indexed by (kind - TOK_COLON), i.e. 0..9
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

msg_parse_prefix:     db "parse error: "
msg_parse_prefix_len  equ $ - msg_parse_prefix
msg_at_line:          db " at line "
msg_at_line_len       equ $ - msg_at_line
msg_col:              db ", col "
msg_col_len           equ $ - msg_col
msg_byte_offset:      db " (byte offset "
msg_byte_offset_len   equ $ - msg_byte_offset
msg_found:            db "), found "
msg_found_len         equ $ - msg_found
nl_byte:              db 10

section .text

; ===========================================================================
; parser_init: sets up the lookahead buffer over a source span and primes
; tok_cur with the first real token.
; in: rdi = src buffer pointer, rsi = starting byte offset, rdx = valid length
; ===========================================================================
parser_init:
    mov     [parser_src_buf], rdi
    mov     [raw_cursor], rsi
    mov     [parser_src_len], rdx
    mov     qword [tok_peek_valid], 0
    call    parser_advance
    ret

; ===========================================================================
; parser_advance: consumes tok_cur, replacing it with the next token --
; either the already-memoized tok_peek (cheap), or a fresh lex_next call.
; ===========================================================================
parser_advance:
    cmp     qword [tok_peek_valid], 0
    je      .fetch
    ; promote tok_peek -> tok_cur (32-byte copy)
    push    rsi
    push    rdi
    push    rcx
    mov     rsi, tok_peek
    mov     rdi, tok_cur
    mov     rcx, TOKEN_SIZE
    rep     movsb
    pop     rcx
    pop     rdi
    pop     rsi
    mov     qword [tok_peek_valid], 0
    ret
.fetch:
    mov     rdi, [parser_src_buf]
    mov     rsi, [raw_cursor]
    mov     rdx, [parser_src_len]
    mov     rcx, tok_cur
    call    lex_next
    mov     [raw_cursor], rax
    ret

; ===========================================================================
; parser_peek: ensures tok_peek holds the token after tok_cur, without
; consuming anything. out: rax = tok_peek's address.
; ===========================================================================
parser_peek:
    cmp     qword [tok_peek_valid], 0
    jne     .done
    mov     rdi, [parser_src_buf]
    mov     rsi, [raw_cursor]
    mov     rdx, [parser_src_len]
    mov     rcx, tok_peek
    call    lex_next
    mov     [raw_cursor], rax
    mov     qword [tok_peek_valid], 1
.done:
    mov     rax, tok_peek
    ret

; ===========================================================================
; parser_expect: consumes tok_cur if it matches the expected kind, otherwise
; reports a parse error (never returns). Collapses the extremely common
; "consume this required token or die" pattern into one call.
; in: rdi = expected TOK_* kind, rsi/rdx = error message (used only on
;     mismatch -- left untouched on the fast path, see below)
; ===========================================================================
parser_expect:
    mov     rax, [tok_cur + TOK_KIND_OFF]
    cmp     rax, rdi
    jne     .mismatch
    jmp     parser_advance      ; tail call: parser_advance's `ret` returns
                                 ; directly to parser_expect's own caller
.mismatch:
    call    report_parse_error  ; rsi/rdx still hold the caller's message

; ===========================================================================
; report_parse_error: builds "parse error: <msg> at line L, col C (byte
; offset O), found <token-desc>\n" into err_buf, writes it to stderr,
; exit(1). Never returns.
; in: rsi = message ptr, rdx = message len
; ===========================================================================
report_parse_error:
    mov     qword [err_cursor], 0
    mov     [perr_msg_ptr], rsi
    mov     [perr_msg_len], rdx

    mov     rax, [tok_cur + TOK_OFFSET_OFF]
    mov     [perr_offset], rax
    mov     rdi, rax
    call    compute_line_col
    mov     [perr_line], rax
    mov     [perr_col], rdx

    mov     rsi, msg_parse_prefix
    mov     rdx, msg_parse_prefix_len
    call    err_append_str

    mov     rsi, [perr_msg_ptr]
    mov     rdx, [perr_msg_len]
    call    err_append_str

    mov     rsi, msg_at_line
    mov     rdx, msg_at_line_len
    call    err_append_str

    mov     rax, [perr_line]
    call    err_append_dec

    mov     rsi, msg_col
    mov     rdx, msg_col_len
    call    err_append_str

    mov     rax, [perr_col]
    call    err_append_dec

    mov     rsi, msg_byte_offset
    mov     rdx, msg_byte_offset_len
    call    err_append_str

    mov     rax, [perr_offset]
    call    err_append_dec

    mov     rsi, msg_found
    mov     rdx, msg_found_len
    call    err_append_str

    call    err_append_token_desc

    mov     rsi, nl_byte
    mov     rdx, 1
    call    err_append_str

    mov     rdi, 2
    mov     rsi, err_buf
    mov     rdx, [err_cursor]
    call    write_all

    mov     rax, 60
    mov     rdi, 1
    syscall

; ===========================================================================
; err_append_token_desc: appends a human-readable description of [tok_cur]
; to err_buf. Mirrors the lexer driver's format_and_emit_token dispatch
; (same kind-range logic), targeting err_append_str instead of emit_str.
; Identifiers/keywords/int-literals/operators all re-slice their exact
; source span from parser_src_buf -- no separate spelling table needed for
; any of those; only structural punctuation needs the bare-label table.
; ===========================================================================
err_append_token_desc:
    mov     rax, [tok_cur + TOK_KIND_OFF]

    cmp     rax, TOK_EOF
    jne     .not_eof
    mov     rsi, str_EOF
    mov     rdx, str_EOF_len
    jmp     err_append_str
.not_eof:
    cmp     rax, TOK_IDENT
    jne     .not_ident
    mov     rsi, str_IDENT
    mov     rdx, str_IDENT_len
    call    err_append_str
    jmp     .emit_span
.not_ident:
    cmp     rax, TOK_INT
    jne     .not_int
    mov     rsi, str_INT
    mov     rdx, str_INT_len
    call    err_append_str
    jmp     .emit_span
.not_int:
    cmp     rax, TOK_KW_FUNCTION
    jl      .not_kw
    cmp     rax, TOK_KW_VOID
    jg      .not_kw
    mov     rsi, str_KW
    mov     rdx, str_KW_len
    call    err_append_str
    jmp     .emit_span
.not_kw:
    cmp     rax, TOK_ASSIGN
    jl      .not_op
    cmp     rax, TOK_PIPE
    jg      .not_op
    mov     rsi, str_OP
    mov     rdx, str_OP_len
    call    err_append_str
    jmp     .emit_span
.not_op:
    cmp     rax, TOK_COLON
    jl      .unknown
    cmp     rax, TOK_RBRACKET
    jg      .unknown
    mov     rcx, rax
    sub     rcx, TOK_COLON
    shl     rcx, 4              ; byte offset = index * 16 (scale factors only allow 1/2/4/8)
    mov     rsi, [punct_labels + rcx]
    mov     rdx, [punct_labels + rcx + 8]
    jmp     err_append_str
.unknown:
    ret
.emit_span:
    mov     rax, [tok_cur + TOK_OFFSET_OFF]
    mov     rsi, [parser_src_buf]
    add     rsi, rax
    mov     rdx, [tok_cur + TOK_LENGTH_OFF]
    jmp     err_append_str
