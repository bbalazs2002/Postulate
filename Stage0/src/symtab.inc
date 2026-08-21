; Postulate Stage 0 -- semantic analyzer symbol-table record layouts.
; Shared between symtab.asm (writer) and sema_expr.asm/sema_stmt.asm
; (readers) -- genuinely cross-file layout, so factored into its own .inc
; rather than duplicated per file (unlike the tiny local diagnostic message
; strings elsewhere in this codebase, which ARE duplicated per file).
;
; No nested scopes to model: Stage 0 only allows `decl` at a func_block's
; own top (never inside if/while bodies), so there is exactly one flat
; local scope per function (its params + its own decls) -- no shadowing,
; no scope stack. All three tables below are flat arrays, linear-scanned,
; matching this codebase's established "MAX_LIST_ARITY-capped array +
; bytes_equal" idiom for every other variable-arity collection.

; --- struct_table entry: 24 bytes ---
STE_NAME_OFF  equ 0
STE_NAME_LEN  equ 8
STE_DECL_PTR  equ 16   ; AST_STRUCT_DECL node ptr
STRUCT_ENTRY_SIZE equ 24

; --- callable_table entry: 40 bytes -- unifies function + extern function,
; since both are "callable by name" identically from a call-expression's
; point of view; is_extern only matters for whitelist validation, not for
; call-site checking. ---
CTE_NAME_OFF   equ 0
CTE_NAME_LEN   equ 8
CTE_IS_EXTERN  equ 16   ; 0 = AST_FUNCTION, 1 = AST_EXTERN_DECL
CTE_SIG_PTR    equ 24   ; AST_SIGNATURE node ptr (name/params already on it)
CTE_RET_TYPE   equ 32   ; type node ptr, 0 = void
CALLABLE_ENTRY_SIZE equ 40

; --- local_table entry: 32 bytes -- one function's flat scope (params +
; func_block decls). Rebuilt fresh before checking each function body. ---
LTE_NAME_OFF   equ 0
LTE_NAME_LEN   equ 8
LTE_TYPE_PTR   equ 16
LTE_IS_CONST   equ 24
LOCAL_ENTRY_SIZE equ 32
