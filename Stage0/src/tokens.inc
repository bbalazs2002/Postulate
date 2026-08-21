; Postulate Stage 0 -- token kind constants and token-struct layout.
; See docs/postulate_stage0_lexer_spec.md section 4.

; --- sentinels ---
TOK_EOF          equ 0
TOK_IDENT        equ 1
TOK_INT          equ 2

; --- keywords (24) ---
TOK_KW_FUNCTION  equ 10
TOK_KW_STRUCT    equ 11
TOK_KW_EXTERN    equ 12
TOK_KW_MUT       equ 13
TOK_KW_CONST     equ 14
TOK_KW_IF        equ 15
TOK_KW_ELSE      equ 16
TOK_KW_WHILE     equ 17
TOK_KW_RETURN    equ 18
TOK_KW_TRUE      equ 19
TOK_KW_FALSE     equ 20
TOK_KW_NULL      equ 21
TOK_KW_INT8      equ 22
TOK_KW_INT16     equ 23
TOK_KW_INT       equ 24
TOK_KW_INT32     equ 25
TOK_KW_INT64     equ 26
TOK_KW_UINT8     equ 27
TOK_KW_UINT16    equ 28
TOK_KW_UINT      equ 29
TOK_KW_UINT32    equ 30
TOK_KW_UINT64    equ 31
TOK_KW_BOOL      equ 32
TOK_KW_VOID      equ 33

; --- structural punctuation (bare-name dump, no spelling echoed) ---
TOK_COLON        equ 40   ; :
TOK_SEMI         equ 41   ; ;
TOK_COMMA        equ 42   ; ,
TOK_DOT          equ 43   ; .
TOK_LPAREN       equ 44   ; (
TOK_RPAREN       equ 45   ; )
TOK_LBRACE       equ 46   ; {
TOK_RBRACE       equ 47   ; }
TOK_LBRACKET     equ 48   ; [
TOK_RBRACKET     equ 49   ; ]

; --- operators ("OP <sym>" dump) ---
TOK_ASSIGN       equ 60   ; :=
TOK_EQ           equ 61   ; ==
TOK_NE           equ 62   ; !=
TOK_LE           equ 63   ; <=
TOK_GE           equ 64   ; >=
TOK_SHL          equ 65   ; <<
TOK_SHR          equ 66   ; >>
TOK_ANDAND       equ 67   ; &&
TOK_OROR         equ 68   ; ||
TOK_BANG         equ 69   ; !
TOK_MINUS        equ 70   ; -
TOK_STAR         equ 71   ; *
TOK_AMP          equ 72   ; &
TOK_SLASH        equ 73   ; /
TOK_PERCENT      equ 74   ; %
TOK_PLUS         equ 75   ; +
TOK_LT           equ 76   ; <
TOK_GT           equ 77   ; >
TOK_CARET        equ 78   ; ^
TOK_PIPE         equ 79   ; |

; --- errors (never silently swallowed -- see spec section 7) ---
TOK_ERROR_COMMENT equ 253 ; unterminated /* ... at EOF
TOK_ERROR          equ 254 ; unrecognized character

; --- token struct: 4 qwords, 32 bytes total ---
TOKEN_SIZE       equ 32
TOK_KIND_OFF     equ 0
TOK_OFFSET_OFF   equ 8    ; byte offset in src_buf of token's first byte
TOK_LENGTH_OFF   equ 16   ; length in bytes of the token's source span
TOK_VALUE_OFF    equ 24   ; TOK_INT: computed numeric value; else 0
