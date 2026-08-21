; Kulcsszavak
["function" "extern" "struct" "if" "else" "while" "return" "mut" "const"] @keyword

; Típusok
(return_type "void" @type.builtin)
(base_type) @type

; Függvények
(function name: (identifier) @function)
(call_expression function: (identifier) @function.call)

; Változók és Mezők
(field_decl name: (identifier) @property)
(parameter name: (identifier) @variable.parameter)
(decl name: (identifier) @variable)

; Literálok
(integer_literal) @number
(bool_literal) @boolean
(null_literal) @constant.builtin

; Operátorok és Írásjelek
["+" "-" "*" "/" "%" "==" "!=" "<" ">" "<=" ">=" "&&" "||" "!" "&" "|" "^" "<<" ">>" ":="] @operator
["(" ")" "{" "}" "[" "]" ":" ";" ","] @punctuation.bracket