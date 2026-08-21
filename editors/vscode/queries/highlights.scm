; Kulcsszavak
["function" "extern" "struct" "if" "else" "while" "return" "mut" "const"] @keyword

; Típusok
(return_type "void" @type.builtin)
(base_type) @type

; Függvények
(function name: (identifier) @function)
; NOTE: hívás-kiemelés (function.call) nincs -- a nyelvtanban a hívás a
; postfix_op egyik ága, testvére (nem szülője) a hívott azonosítónak, így
; statikus lekérdezéssel nem különböztethető meg egy sima azonosítótól
; nyelvtan-módosítás (pl. mező hozzáadása) nélkül.

; Változók és Mezők
(field_decl name: (identifier) @property)
(param name: (identifier) @variable.parameter)
(decl name: (identifier) @variable)

; Literálok
(integer_literal) @number
(bool_literal) @boolean
(null_literal) @constant.builtin

; Kommentek
(comment) @comment

; Operátorok és Írásjelek
["+" "-" "*" "/" "%" "==" "!=" "<" ">" "<=" ">=" "&&" "||" "!" "&" "|" "^" "<<" ">>" ":="] @operator
["(" ")" "{" "}" "[" "]" ":" ";" ","] @punctuation.bracket