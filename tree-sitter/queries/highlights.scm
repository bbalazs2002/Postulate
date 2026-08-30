; Keywords
["function" "extern" "struct" "if" "else" "while" "return" "mut" "const"
 "namespace" "use" "as" "verified" "unverified" "sizeof" "lengthof"] @keyword
"@autoload" @keyword

; Types
(base_type) @type

; Functions
(function name: (identifier) @function)
; NOTE: no call highlighting (function.call) -- in the grammar, a call is
; one branch of postfix_op, a sibling (not a parent) of the called
; identifier, so it can't be distinguished from a plain identifier via a
; static query without a grammar change (e.g. adding a field).

; Namespaces and imports
(namespace_decl path: (namespace_path) @namespace)
(use_decl path: (namespace_path) @namespace)
(use_decl alias: (identifier) @namespace)
(use_group_item name: (identifier) @variable)
(use_group_item alias: (identifier) @namespace)
(autoload_decl pattern: (string_literal) @string)
(autoload_decl path: (string_literal) @string)

; Variables and fields
(field_decl name: (identifier) @property)
(param name: (identifier) @variable.parameter)
(decl name: (identifier) @variable)

; Literals
(integer_literal) @number
(char_literal) @string
(string_literal) @string
(bool_literal) @boolean
(null_literal) @constant.builtin

; Comments
(comment) @comment

; Operators and punctuation
["+" "-" "*" "/" "%" "==" "!=" "<" ">" "<=" ">=" "&&" "||" "!" "&" "|" "^" "<<" ">>" ":="] @operator
["(" ")" "{" "}" "[" "]" ":" ";" "," "\\"] @punctuation.bracket
