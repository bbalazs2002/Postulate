; Postulate Stage 0 -- shared syscall I/O and diagnostic-formatting runtime.
;
; Extracted from the original lexer-only main.asm so the lexer binary and
; the parser binary can both link against one copy instead of duplicating
; it (see docs/postulate_stage0_parser_spec.md section 3). Pure extraction:
; no behavior changed relative to the original main.asm.
;
; Internal calling convention: System V AMD64 caller/callee-saved register
; split, same as lexer.asm/main.asm. Every routine documents which
; callee-saved registers it uses.

%include "config.inc"

global read_all
global write_all
global emit_str
global flush_out
global compute_line_col
global err_append_str
global err_append_dec
global err_append_hex_byte

global src_buf
global src_len
global err_buf
global err_cursor

section .bss
src_buf:      resb SRC_BUF_SIZE
scratch_byte: resb 1              ; read_all: disambiguates exact-fit vs overflow
src_len:      resq 1
out_buf:      resb OUT_BUF_SIZE
out_cursor:   resq 1
err_buf:      resb 512
err_cursor:   resq 1

section .data
msg_buf_full:      db "stage0: input exceeds fixed source buffer", 10
msg_buf_full_len   equ $ - msg_buf_full
msg_read_fail:     db "stage0: read() failed", 10
msg_read_fail_len  equ $ - msg_read_fail
msg_write_fail:    db "stage0: write() failed", 10
msg_write_fail_len equ $ - msg_write_fail

section .text

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
; emit_str / flush_out: buffered stdout writer.
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
    ; a single span exceeds the entire output buffer -- unrecoverable for
    ; this fixed-buffer design (I/O-class failure)
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
; compute_line_col: in rdi = byte offset into src_buf; out rax = line
; (1-based), rdx = col (1-based). One-time backward-style scan, only ever
; called on an error path.
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
; err_append_str / err_append_dec / err_append_hex_byte: unbuffered (single
; write at the end) formatting helpers for a one-shot diagnostic message
; built into err_buf (512 bytes -- generous relative to one diagnostic
; line, so these never need a flush-on-overflow path). Callers are
; responsible for zeroing err_cursor before the first append and for
; write_all-ing err_buf/err_cursor to stderr once the message is complete.
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
