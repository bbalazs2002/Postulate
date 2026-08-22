; Keywords
["function" "extern" "struct" "if" "else" "while" "return" "mut" "const"] @keyword

; Types
(return_type "void" @type.builtin)
(base_type) @type

; Functions
(function name: (identifier) @function)
; NOTE: no call highlighting (function.call) -- in the grammar, a call is
; one branch of postfix_op, a sibling (not a parent) of the called
; identifier, so it can't be distinguished from a plain identifier via a
; static query without a grammar change (e.g. adding a field).

; Variables and fields
(field_decl name: (identifier) @property)
(param name: (identifier) @variable.parameter)
(decl name: (identifier) @variable)

; Literals
(integer_literal) @number
(bool_literal) @boolean
(null_literal) @constant.builtin

; Comments
(comment) @comment

; Operators and punctuation
["+" "-" "*" "/" "%" "==" "!=" "<" ">" "<=" ">=" "&&" "||" "!" "&" "|" "^" "<<" ">>" ":="] @operator
["(" ")" "{" "}" "[" "]" ":" ";" ","] @punctuation.bracket
