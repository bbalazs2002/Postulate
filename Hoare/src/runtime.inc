; Postulate Stage 0 -- extern declarations for runtime.asm's exports.
; %include this wherever any of these are used from a different object file.

extern read_all
extern write_all
extern emit_str
extern flush_out
extern compute_line_col
extern err_append_str
extern err_append_dec
extern err_append_hex_byte

extern src_buf
extern src_len
extern err_buf
extern err_cursor
