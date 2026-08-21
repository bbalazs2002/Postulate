; Postulate Stage 0 -- lexer engine.
;
; Pure tokenizer: no syscalls, no I/O, no exits. Reads a caller-supplied
; buffer, fills a caller-supplied 32-byte token struct. This is the only
; symbol a future parser needs to link against.
;
; See docs/postulate_stage0_lexer_spec.md sections 4-7 for the design this
; file implements.

%include "config.inc"
%include "tokens.inc"

global lex_next

; ---------------------------------------------------------------------------
; lex_next
; in:  rdi = src buffer pointer
;      rsi = cursor (byte offset to resume scanning from)
;      rdx = buffer length (valid bytes)
;      rcx = pointer to a caller-owned 32-byte token struct to fill
; out: rax = new cursor (pass back in as rsi on the next call)
;      [rcx] = filled token struct
;
; Register usage for the whole lex_next/lex_handle_*/lex_epilogue group:
;   r12 = buf pointer   (loaded once, never changes)
;   r13 = buffer length (loaded once, never changes)
;   r14 = token struct pointer (loaded once, never changes)
;   rbx = cursor / current scan position (the "working" register)
;   r15 = start offset of the token currently being scanned
; All five are callee-saved per our internal convention -- pushed at entry,
; popped in lex_epilogue right before ret.
; ---------------------------------------------------------------------------
lex_next:
    push    rbx
    push    r12
    push    r13
    push    r14
    push    r15
    mov     r12, rdi
    mov     rbx, rsi
    mov     r13, rdx
    mov     r14, rcx

; --- trivia: whitespace and comments (spec section 6.3) ---
.trivia_loop:
    cmp     rbx, r13
    jae     .at_eof
    movzx   eax, byte [r12 + rbx]
    cmp     al, ' '
    je      .ws
    cmp     al, 9               ; tab
    je      .ws
    cmp     al, 13              ; CR
    je      .ws
    cmp     al, 10              ; LF
    je      .ws
    cmp     al, '/'
    je      .maybe_comment
    jmp     .dispatch
.ws:
    inc     rbx
    jmp     .trivia_loop

.maybe_comment:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .dispatch           ; '/' is the last byte -> real token (TOK_SLASH)
    movzx   eax, byte [r12 + rbx + 1]
    cmp     al, '/'
    je      .line_comment
    cmp     al, '*'
    je      .block_comment
    jmp     .dispatch           ; '/' followed by something else -> real token

.line_comment:
    add     rbx, 2
.line_comment_loop:
    cmp     rbx, r13
    jae     .trivia_loop        ; EOF ends the line comment successfully
    cmp     byte [r12 + rbx], 10
    je      .line_comment_end
    inc     rbx
    jmp     .line_comment_loop
.line_comment_end:
    inc     rbx
    jmp     .trivia_loop

.block_comment:
    mov     r15, rbx            ; remember the opening "/*" position for the error case
    add     rbx, 2
.block_comment_loop:
    cmp     rbx, r13
    jae     .block_comment_unterminated
    cmp     byte [r12 + rbx], '*'
    jne     .block_comment_advance
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .block_comment_unterminated
    cmp     byte [r12 + rbx + 1], '/'
    jne     .block_comment_advance
    add     rbx, 2
    jmp     .trivia_loop
.block_comment_advance:
    inc     rbx
    jmp     .block_comment_loop
.block_comment_unterminated:
    mov     qword [r14 + TOK_KIND_OFF], TOK_ERROR_COMMENT
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 0
    mov     qword [r14 + TOK_VALUE_OFF], 0
    mov     rax, rbx
    jmp     lex_epilogue

.at_eof:
    mov     qword [r14 + TOK_KIND_OFF], TOK_EOF
    mov     [r14 + TOK_OFFSET_OFF], rbx
    mov     qword [r14 + TOK_LENGTH_OFF], 0
    mov     qword [r14 + TOK_VALUE_OFF], 0
    mov     rax, rbx
    jmp     lex_epilogue

; --- dispatch on the first byte of a real token (spec section 6.1) ---
.dispatch:
    mov     r15, rbx
    movzx   eax, byte [r12 + rbx]
    jmp     [dispatch_tbl + rax*8]

; ---------------------------------------------------------------------------
; lex_epilogue: shared exit point for every handler below.
; Precondition: rax = new cursor, [r14+...] = fully-filled token struct.
; ---------------------------------------------------------------------------
lex_epilogue:
    pop     r15
    pop     r14
    pop     r13
    pop     r12
    pop     rbx
    ret

; ---------------------------------------------------------------------------
; Identifier / keyword (spec section 6.4)
; ---------------------------------------------------------------------------
lex_handle_ident:
.ident_loop:
    inc     rbx
    cmp     rbx, r13
    jae     .ident_end
    movzx   eax, byte [r12 + rbx]
    cmp     al, 'a'
    jl      .check_upper
    cmp     al, 'z'
    jle     .ident_loop
.check_upper:
    cmp     al, 'A'
    jl      .check_digit
    cmp     al, 'Z'
    jle     .ident_loop
.check_digit:
    cmp     al, '0'
    jl      .check_us
    cmp     al, '9'
    jle     .ident_loop
.check_us:
    cmp     al, '_'
    je      .ident_loop
    ; fall through: byte does not continue the identifier
.ident_end:
    mov     rax, rbx
    sub     rax, r15            ; length
    call    lex_classify_ident  ; -> rax = kind (TOK_IDENT or a TOK_KW_*)
    mov     [r14 + TOK_KIND_OFF], rax
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     rcx, rbx
    sub     rcx, r15
    mov     [r14 + TOK_LENGTH_OFF], rcx
    mov     qword [r14 + TOK_VALUE_OFF], 0
    mov     rax, rbx
    jmp     lex_epilogue

; ---------------------------------------------------------------------------
; lex_classify_ident: length-bucketed keyword lookup (spec section 6.4).
; in:  rax = length, r12 = buf, r15 = token start offset (already live)
; out: rax = kind constant
; clobbers: rax, rcx, rdx only -- an ordinary `call`ed leaf routine.
; ---------------------------------------------------------------------------
lex_classify_ident:
    cmp     rax, 2
    je      .len2
    cmp     rax, 3
    je      .len3
    cmp     rax, 4
    je      .len4
    cmp     rax, 5
    je      .len5
    cmp     rax, 6
    je      .len6
    cmp     rax, 8
    je      .len8
    jmp     .is_ident

; -- length 2: if --
.len2:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'f'
    jne     .is_ident
    mov     rax, TOK_KW_IF
    ret

; -- length 3: mut, int --
.len3:
.try_mut:
    cmp     byte [r12 + r15 + 0], 'm'
    jne     .try_int3
    cmp     byte [r12 + r15 + 1], 'u'
    jne     .try_int3
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_int3
    mov     rax, TOK_KW_MUT
    ret
.try_int3:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'n'
    jne     .is_ident
    cmp     byte [r12 + r15 + 2], 't'
    jne     .is_ident
    mov     rax, TOK_KW_INT
    ret

; -- length 4: else, true, null, int8, bool, void, uint --
.len4:
.try_else:
    cmp     byte [r12 + r15 + 0], 'e'
    jne     .try_true
    cmp     byte [r12 + r15 + 1], 'l'
    jne     .try_true
    cmp     byte [r12 + r15 + 2], 's'
    jne     .try_true
    cmp     byte [r12 + r15 + 3], 'e'
    jne     .try_true
    mov     rax, TOK_KW_ELSE
    ret
.try_true:
    cmp     byte [r12 + r15 + 0], 't'
    jne     .try_null
    cmp     byte [r12 + r15 + 1], 'r'
    jne     .try_null
    cmp     byte [r12 + r15 + 2], 'u'
    jne     .try_null
    cmp     byte [r12 + r15 + 3], 'e'
    jne     .try_null
    mov     rax, TOK_KW_TRUE
    ret
.try_null:
    cmp     byte [r12 + r15 + 0], 'n'
    jne     .try_int8
    cmp     byte [r12 + r15 + 1], 'u'
    jne     .try_int8
    cmp     byte [r12 + r15 + 2], 'l'
    jne     .try_int8
    cmp     byte [r12 + r15 + 3], 'l'
    jne     .try_int8
    mov     rax, TOK_KW_NULL
    ret
.try_int8:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .try_bool
    cmp     byte [r12 + r15 + 1], 'n'
    jne     .try_bool
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_bool
    cmp     byte [r12 + r15 + 3], '8'
    jne     .try_bool
    mov     rax, TOK_KW_INT8
    ret
.try_bool:
    cmp     byte [r12 + r15 + 0], 'b'
    jne     .try_void
    cmp     byte [r12 + r15 + 1], 'o'
    jne     .try_void
    cmp     byte [r12 + r15 + 2], 'o'
    jne     .try_void
    cmp     byte [r12 + r15 + 3], 'l'
    jne     .try_void
    mov     rax, TOK_KW_BOOL
    ret
.try_void:
    cmp     byte [r12 + r15 + 0], 'v'
    jne     .try_uint4
    cmp     byte [r12 + r15 + 1], 'o'
    jne     .try_uint4
    cmp     byte [r12 + r15 + 2], 'i'
    jne     .try_uint4
    cmp     byte [r12 + r15 + 3], 'd'
    jne     .try_uint4
    mov     rax, TOK_KW_VOID
    ret
.try_uint4:
    cmp     byte [r12 + r15 + 0], 'u'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .is_ident
    cmp     byte [r12 + r15 + 3], 't'
    jne     .is_ident
    mov     rax, TOK_KW_UINT
    ret

; -- length 5: const, while, false, int16, int32, int64, uint8 --
.len5:
.try_const:
    cmp     byte [r12 + r15 + 0], 'c'
    jne     .try_while
    cmp     byte [r12 + r15 + 1], 'o'
    jne     .try_while
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .try_while
    cmp     byte [r12 + r15 + 3], 's'
    jne     .try_while
    cmp     byte [r12 + r15 + 4], 't'
    jne     .try_while
    mov     rax, TOK_KW_CONST
    ret
.try_while:
    cmp     byte [r12 + r15 + 0], 'w'
    jne     .try_false
    cmp     byte [r12 + r15 + 1], 'h'
    jne     .try_false
    cmp     byte [r12 + r15 + 2], 'i'
    jne     .try_false
    cmp     byte [r12 + r15 + 3], 'l'
    jne     .try_false
    cmp     byte [r12 + r15 + 4], 'e'
    jne     .try_false
    mov     rax, TOK_KW_WHILE
    ret
.try_false:
    cmp     byte [r12 + r15 + 0], 'f'
    jne     .try_int16
    cmp     byte [r12 + r15 + 1], 'a'
    jne     .try_int16
    cmp     byte [r12 + r15 + 2], 'l'
    jne     .try_int16
    cmp     byte [r12 + r15 + 3], 's'
    jne     .try_int16
    cmp     byte [r12 + r15 + 4], 'e'
    jne     .try_int16
    mov     rax, TOK_KW_FALSE
    ret
.try_int16:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .try_int32
    cmp     byte [r12 + r15 + 1], 'n'
    jne     .try_int32
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_int32
    cmp     byte [r12 + r15 + 3], '1'
    jne     .try_int32
    cmp     byte [r12 + r15 + 4], '6'
    jne     .try_int32
    mov     rax, TOK_KW_INT16
    ret
.try_int32:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .try_int64
    cmp     byte [r12 + r15 + 1], 'n'
    jne     .try_int64
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_int64
    cmp     byte [r12 + r15 + 3], '3'
    jne     .try_int64
    cmp     byte [r12 + r15 + 4], '2'
    jne     .try_int64
    mov     rax, TOK_KW_INT32
    ret
.try_int64:
    cmp     byte [r12 + r15 + 0], 'i'
    jne     .try_uint8_5
    cmp     byte [r12 + r15 + 1], 'n'
    jne     .try_uint8_5
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_uint8_5
    cmp     byte [r12 + r15 + 3], '6'
    jne     .try_uint8_5
    cmp     byte [r12 + r15 + 4], '4'
    jne     .try_uint8_5
    mov     rax, TOK_KW_INT64
    ret
.try_uint8_5:
    cmp     byte [r12 + r15 + 0], 'u'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .is_ident
    cmp     byte [r12 + r15 + 3], 't'
    jne     .is_ident
    cmp     byte [r12 + r15 + 4], '8'
    jne     .is_ident
    mov     rax, TOK_KW_UINT8
    ret

; -- length 6: struct, extern, return, uint16, uint32, uint64 --
.len6:
.try_struct:
    cmp     byte [r12 + r15 + 0], 's'
    jne     .try_extern
    cmp     byte [r12 + r15 + 1], 't'
    jne     .try_extern
    cmp     byte [r12 + r15 + 2], 'r'
    jne     .try_extern
    cmp     byte [r12 + r15 + 3], 'u'
    jne     .try_extern
    cmp     byte [r12 + r15 + 4], 'c'
    jne     .try_extern
    cmp     byte [r12 + r15 + 5], 't'
    jne     .try_extern
    mov     rax, TOK_KW_STRUCT
    ret
.try_extern:
    cmp     byte [r12 + r15 + 0], 'e'
    jne     .try_return
    cmp     byte [r12 + r15 + 1], 'x'
    jne     .try_return
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_return
    cmp     byte [r12 + r15 + 3], 'e'
    jne     .try_return
    cmp     byte [r12 + r15 + 4], 'r'
    jne     .try_return
    cmp     byte [r12 + r15 + 5], 'n'
    jne     .try_return
    mov     rax, TOK_KW_EXTERN
    ret
.try_return:
    cmp     byte [r12 + r15 + 0], 'r'
    jne     .try_uint16
    cmp     byte [r12 + r15 + 1], 'e'
    jne     .try_uint16
    cmp     byte [r12 + r15 + 2], 't'
    jne     .try_uint16
    cmp     byte [r12 + r15 + 3], 'u'
    jne     .try_uint16
    cmp     byte [r12 + r15 + 4], 'r'
    jne     .try_uint16
    cmp     byte [r12 + r15 + 5], 'n'
    jne     .try_uint16
    mov     rax, TOK_KW_RETURN
    ret
.try_uint16:
    cmp     byte [r12 + r15 + 0], 'u'
    jne     .try_uint32
    cmp     byte [r12 + r15 + 1], 'i'
    jne     .try_uint32
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .try_uint32
    cmp     byte [r12 + r15 + 3], 't'
    jne     .try_uint32
    cmp     byte [r12 + r15 + 4], '1'
    jne     .try_uint32
    cmp     byte [r12 + r15 + 5], '6'
    jne     .try_uint32
    mov     rax, TOK_KW_UINT16
    ret
.try_uint32:
    cmp     byte [r12 + r15 + 0], 'u'
    jne     .try_uint64
    cmp     byte [r12 + r15 + 1], 'i'
    jne     .try_uint64
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .try_uint64
    cmp     byte [r12 + r15 + 3], 't'
    jne     .try_uint64
    cmp     byte [r12 + r15 + 4], '3'
    jne     .try_uint64
    cmp     byte [r12 + r15 + 5], '2'
    jne     .try_uint64
    mov     rax, TOK_KW_UINT32
    ret
.try_uint64:
    cmp     byte [r12 + r15 + 0], 'u'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .is_ident
    cmp     byte [r12 + r15 + 3], 't'
    jne     .is_ident
    cmp     byte [r12 + r15 + 4], '6'
    jne     .is_ident
    cmp     byte [r12 + r15 + 5], '4'
    jne     .is_ident
    mov     rax, TOK_KW_UINT64
    ret

; -- length 8: function --
.len8:
    cmp     byte [r12 + r15 + 0], 'f'
    jne     .is_ident
    cmp     byte [r12 + r15 + 1], 'u'
    jne     .is_ident
    cmp     byte [r12 + r15 + 2], 'n'
    jne     .is_ident
    cmp     byte [r12 + r15 + 3], 'c'
    jne     .is_ident
    cmp     byte [r12 + r15 + 4], 't'
    jne     .is_ident
    cmp     byte [r12 + r15 + 5], 'i'
    jne     .is_ident
    cmp     byte [r12 + r15 + 6], 'o'
    jne     .is_ident
    cmp     byte [r12 + r15 + 7], 'n'
    jne     .is_ident
    mov     rax, TOK_KW_FUNCTION
    ret

.is_ident:
    mov     rax, TOK_IDENT
    ret

; ---------------------------------------------------------------------------
; Number literals: decimal_form / based_form (spec section 6, 4.3)
; ---------------------------------------------------------------------------
lex_handle_number:
    xor     r9, r9              ; r9 = accumulator
.decimal_loop:
    cmp     rbx, r13
    jae     .decimal_done
    movzx   eax, byte [r12 + rbx]
    cmp     al, '0'
    jl      .decimal_done
    cmp     al, '9'
    jg      .decimal_done
    imul    r9, r9, 10
    movzx   edx, al
    sub     edx, '0'
    add     r9, rdx
    inc     rbx
    jmp     .decimal_loop
.decimal_done:
    cmp     rbx, r13
    jae     .emit_decimal
    cmp     byte [r12 + rbx], 'n'
    jne     .emit_decimal

    ; based_form: r9 currently holds the base
    mov     r8, r9              ; r8 = base
    inc     rbx                 ; consume 'n'
    mov     rcx, rbx            ; rcx = start of the value_digit+ run
    xor     r9, r9              ; reset accumulator for the based value
.based_loop:
    cmp     rbx, r13
    jae     .based_done
    movzx   eax, byte [r12 + rbx]
    cmp     al, '0'
    jl      .based_done
    cmp     al, '9'
    jle     .based_digit
    cmp     al, 'a'
    jl      .based_upper_check
    cmp     al, 'f'
    jle     .based_alpha
    jmp     .based_done
.based_upper_check:
    cmp     al, 'A'
    jl      .based_done
    cmp     al, 'F'
    jg      .based_done
.based_alpha:
    or      al, 0x20            ; fold to lowercase
    movzx   edx, al
    sub     edx, 'a'
    add     edx, 10
    jmp     .based_accum
.based_digit:
    movzx   edx, al
    sub     edx, '0'
.based_accum:
    mov     rax, r9
    imul    rax, r8
    add     rax, rdx
    mov     r9, rax
    inc     rbx
    jmp     .based_loop
.based_done:
    cmp     rbx, rcx
    je      .empty_value_digits
    mov     qword [r14 + TOK_KIND_OFF], TOK_INT
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     rax, rbx
    sub     rax, r15
    mov     [r14 + TOK_LENGTH_OFF], rax
    mov     [r14 + TOK_VALUE_OFF], r9
    mov     rax, rbx
    jmp     lex_epilogue
.empty_value_digits:
    mov     qword [r14 + TOK_KIND_OFF], TOK_ERROR
    mov     [r14 + TOK_OFFSET_OFF], rbx      ; offset = right after the 'n'
    mov     qword [r14 + TOK_LENGTH_OFF], 0
    mov     qword [r14 + TOK_VALUE_OFF], 0
    mov     rax, rbx
    jmp     lex_epilogue
.emit_decimal:
    mov     qword [r14 + TOK_KIND_OFF], TOK_INT
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     rax, rbx
    sub     rax, r15
    mov     [r14 + TOK_LENGTH_OFF], rax
    mov     [r14 + TOK_VALUE_OFF], r9
    mov     rax, rbx
    jmp     lex_epilogue

; ---------------------------------------------------------------------------
; Two-char-lookahead operators (spec section 6.2)
; ---------------------------------------------------------------------------
lex_handle_colon:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    cmp     byte [r12 + rbx + 1], '='
    jne     .bare
    mov     qword [r14 + TOK_KIND_OFF], TOK_ASSIGN
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_COLON
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

lex_handle_equal:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bad
    cmp     byte [r12 + rbx + 1], '='
    jne     .bad
    mov     qword [r14 + TOK_KIND_OFF], TOK_EQ
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue
.bad:
    ; bare '=' is never valid -- there is no fallback single-char token here
    mov     qword [r14 + TOK_KIND_OFF], TOK_ERROR
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

lex_handle_bang:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    cmp     byte [r12 + rbx + 1], '='
    jne     .bare
    mov     qword [r14 + TOK_KIND_OFF], TOK_NE
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_BANG
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

lex_handle_lt:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    movzx   ecx, byte [r12 + rbx + 1]
    cmp     cl, '='
    je      .le
    cmp     cl, '<'
    je      .shl
    jmp     .bare
.le:
    mov     qword [r14 + TOK_KIND_OFF], TOK_LE
    jmp     .emit2
.shl:
    mov     qword [r14 + TOK_KIND_OFF], TOK_SHL
    jmp     .emit2
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_LT
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue
.emit2:
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue

lex_handle_gt:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    movzx   ecx, byte [r12 + rbx + 1]
    cmp     cl, '='
    je      .ge
    cmp     cl, '>'
    je      .shr
    jmp     .bare
.ge:
    mov     qword [r14 + TOK_KIND_OFF], TOK_GE
    jmp     .emit2
.shr:
    mov     qword [r14 + TOK_KIND_OFF], TOK_SHR
    jmp     .emit2
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_GT
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue
.emit2:
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue

lex_handle_amp:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    cmp     byte [r12 + rbx + 1], '&'
    jne     .bare
    mov     qword [r14 + TOK_KIND_OFF], TOK_ANDAND
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_AMP
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

lex_handle_pipe:
    lea     rax, [rbx + 1]
    cmp     rax, r13
    jae     .bare
    cmp     byte [r12 + rbx + 1], '|'
    jne     .bare
    mov     qword [r14 + TOK_KIND_OFF], TOK_OROR
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 2
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 2]
    jmp     lex_epilogue
.bare:
    mov     qword [r14 + TOK_KIND_OFF], TOK_PIPE
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

; ---------------------------------------------------------------------------
; Single-char-only punctuation/operators
; ---------------------------------------------------------------------------
%macro EMIT_SINGLE 2
%1:
    mov     qword [r14 + TOK_KIND_OFF], %2
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue
%endmacro

EMIT_SINGLE lex_handle_semi,     TOK_SEMI
EMIT_SINGLE lex_handle_comma,    TOK_COMMA
EMIT_SINGLE lex_handle_dot,      TOK_DOT
EMIT_SINGLE lex_handle_lparen,   TOK_LPAREN
EMIT_SINGLE lex_handle_rparen,   TOK_RPAREN
EMIT_SINGLE lex_handle_lbrace,   TOK_LBRACE
EMIT_SINGLE lex_handle_rbrace,   TOK_RBRACE
EMIT_SINGLE lex_handle_lbracket, TOK_LBRACKET
EMIT_SINGLE lex_handle_rbracket, TOK_RBRACKET
EMIT_SINGLE lex_handle_minus,    TOK_MINUS
EMIT_SINGLE lex_handle_star,     TOK_STAR
EMIT_SINGLE lex_handle_slash,    TOK_SLASH
EMIT_SINGLE lex_handle_percent,  TOK_PERCENT
EMIT_SINGLE lex_handle_plus,     TOK_PLUS
EMIT_SINGLE lex_handle_caret,    TOK_CARET

lex_handle_bad_char:
    mov     qword [r14 + TOK_KIND_OFF], TOK_ERROR
    mov     [r14 + TOK_OFFSET_OFF], r15
    mov     qword [r14 + TOK_LENGTH_OFF], 1
    mov     qword [r14 + TOK_VALUE_OFF], 0
    lea     rax, [rbx + 1]
    jmp     lex_epilogue

; ---------------------------------------------------------------------------
; 256-entry first-byte dispatch table (spec section 6.1). Built via the NASM
; preprocessor so every one of the 256 byte values gets an explicit entry --
; letters route to lex_handle_ident, digits to lex_handle_number, each
; punctuation/operator byte to its own handler, everything else (including
; a leading '_', which the grammar does not allow as an identifier's first
; character) to lex_handle_bad_char.
; ---------------------------------------------------------------------------
section .data
align 8
dispatch_tbl:
%assign i 0
%rep 256
    %if i >= 'a' && i <= 'z'
        dq lex_handle_ident
    %elif i >= 'A' && i <= 'Z'
        dq lex_handle_ident
    %elif i >= '0' && i <= '9'
        dq lex_handle_number
    %elif i == ':'
        dq lex_handle_colon
    %elif i == '='
        dq lex_handle_equal
    %elif i == '!'
        dq lex_handle_bang
    %elif i == '<'
        dq lex_handle_lt
    %elif i == '>'
        dq lex_handle_gt
    %elif i == '&'
        dq lex_handle_amp
    %elif i == '|'
        dq lex_handle_pipe
    %elif i == ';'
        dq lex_handle_semi
    %elif i == ','
        dq lex_handle_comma
    %elif i == '.'
        dq lex_handle_dot
    %elif i == '('
        dq lex_handle_lparen
    %elif i == ')'
        dq lex_handle_rparen
    %elif i == '{'
        dq lex_handle_lbrace
    %elif i == '}'
        dq lex_handle_rbrace
    %elif i == '['
        dq lex_handle_lbracket
    %elif i == ']'
        dq lex_handle_rbracket
    %elif i == '-'
        dq lex_handle_minus
    %elif i == '*'
        dq lex_handle_star
    %elif i == '/'
        dq lex_handle_slash
    %elif i == '%'
        dq lex_handle_percent
    %elif i == '+'
        dq lex_handle_plus
    %elif i == '^'
        dq lex_handle_caret
    %else
        dq lex_handle_bad_char
    %endif
%assign i i+1
%endrep
