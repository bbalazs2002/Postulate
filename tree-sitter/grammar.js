// Postulate v1.0 grammar -- what Edsger_v0 actually accepts today
// (docs/postulate_v1_0_language_reference.md), not the full, aspirational
// v1 design and not the original, frozen v0. See grammar-v0-legacy.js for
// the earlier, v0-only grammar this replaces (kept for reference, not
// built/shipped by anything).

module.exports = grammar({
  name: 'postulate',

  extras: $ => [
    /\s/,
    $.comment,
  ],

  conflicts: $ => [
    [$.lvalue, $.primary],
    [$.namespace_path],
    [$.base_type, $.primary],
  ],

  rules: {
    // A real file always starts with exactly one namespace declaration
    // (mandatory in the real language -- a file with none is a compile
    // error), followed by any mix of use/@autoload directives and
    // ordinary top-level declarations. `namespace_decl` is kept optional
    // *here* anyway -- a highlighter's job is graceful partial
    // highlighting of whatever text exists (mid-edit, or an isolated
    // snippet, e.g. Edsger_v0/tests/lexer_cases/'s own namespace-less
    // fixtures), not re-enforcing Sema's own hard requirement.
    program: $ => seq(optional($.namespace_decl), repeat($.top_level_decl)),

    top_level_decl: $ => choice(
      $.use_decl,
      $.autoload_decl,
      $.function,
      $.struct_decl,
      $.extern_decl
    ),

    // --- NAMESPACE, USE, @autoload ---
    namespace_decl: $ => seq(
      'namespace',
      field('path', $.namespace_path),
      ';'
    ),

    namespace_path: $ => seq('\\', $.identifier, repeat(seq('\\', $.identifier))),

    use_decl: $ => seq(
      'use',
      field('path', $.namespace_path),
      optional(choice(
        seq('as', field('alias', $.identifier)),
        seq('\\', '{', $.use_group_item, repeat(seq(',', $.use_group_item)), '}')
      )),
      ';'
    ),

    use_group_item: $ => seq(
      field('name', $.identifier),
      optional(seq('as', field('alias', $.identifier)))
    ),

    // Real syntax, confirmed against Edsger_v0/tests/lexer_cases/
    // lex_test_02_autoload.ptl (an actual fixture, checked against the
    // real lexer) rather than postulate_v1_0_language_reference.md
    // §6.4's own prose example -- that doc shows `"pattern" => "path"`,
    // but the real, tested fixture uses parenthesized, comma-separated
    // arguments, matching the full v1 design's own @autoload shape
    // instead: `@autoload("\Pattern\", "path", verified);`. `@autoload`
    // itself is one fixed token, since `@` cannot start an identifier.
    autoload_decl: $ => seq(
      '@autoload',
      '(',
      field('pattern', $.string_literal),
      ',',
      field('path', $.string_literal),
      optional(seq(',', choice('verified', 'unverified'))),
      ')',
      ';'
    ),

    // --- STRUCT & EXTERN ---
    struct_decl: $ => seq(
      'struct',
      field('name', $.identifier),
      '{',
      repeat1($.field_decl),
      '}'
    ),

    field_decl: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $.type),
      ';'
    ),

    extern_decl: $ => seq(
      'extern',
      'function',
      field('name', $.identifier),
      '(', optional($.params), ')',
      ':',
      field('return_type', $.return_type),
      ';'
    ),

    // --- FUNCTION & PARAMS ---
    function: $ => seq(
      'function',
      field('name', $.identifier),
      '(', optional($.params), ')',
      ':',
      field('return_type', $.return_type),
      $.func_block
    ),

    // `void` lives in base_type now (needed for `*void`), so a return
    // type is just an ordinary type -- kept as its own named rule so
    // highlighting/field queries don't need to change shape.
    return_type: $ => $.type,

    params: $ => seq($.param, repeat(seq(',', $.param))),

    param: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $.type)
    ),

    // --- BLOCKS & DECLARATIONS ---
    func_block: $ => seq(
      '{',
      repeat($.decl),
      repeat($.stmt),
      '}'
    ),

    block: $ => seq('{', repeat($.stmt), '}'),

    decl: $ => seq(
      choice('mut', 'const'),
      field('name', $.identifier),
      ':',
      field('type', $.type),
      optional(seq(':=', field('value', $.expr))),
      ';'
    ),

    // --- STATEMENTS ---
    stmt: $ => choice(
      $.assign_stmt,
      $.if_stmt,
      $.while_stmt,
      $.return_stmt,
      $.expr_stmt
    ),

    assign_pair: $ => seq($.lvalue, ':=', $.expr),
    assign_stmt: $ => seq($.assign_pair, repeat(seq(',', $.assign_pair)), ';'),

    lvalue: $ => choice(
      seq('*', $.lvalue),
      seq($.identifier, repeat(choice(seq('[', $.expr, ']'), seq('.', $.identifier))))
    ),

    if_stmt: $ => seq(
      'if', '(', $.expr, ')',
      $.block,
      optional(seq('else', $.block))
    ),

    while_stmt: $ => seq('while', '(', $.expr, ')', $.block),
    return_stmt: $ => seq('return', optional($.expr), ';'),
    expr_stmt: $ => seq($.expr, ';'),

    // --- EXPRESSIONS ---
    // Precedence ladder per postulate_v1_0_language_reference.md §3.1,
    // loosest to tightest: || && comparison | ^ & << >> + - * / % as
    // unary postfix -- `as` is new over v0, sitting between
    // multiplicative and unary.
    expr: $ => $.logic_or,

    logic_or: $ => prec.left(1, seq($.logic_and, repeat(seq('||', $.logic_and)))),
    logic_and: $ => prec.left(2, seq($.comparison, repeat(seq('&&', $.comparison)))),
    comparison: $ => prec.left(3, seq($.bit_or, optional(seq(choice('==', '!=', '<', '>', '<=', '>='), $.bit_or)))),
    bit_or: $ => prec.left(4, seq($.bit_xor, repeat(seq('|', $.bit_xor)))),
    bit_xor: $ => prec.left(5, seq($.bit_and, repeat(seq('^', $.bit_and)))),
    bit_and: $ => prec.left(6, seq($.shift, repeat(seq('&', $.shift)))),
    shift: $ => prec.left(7, seq($.additive, repeat(seq(choice('<<', '>>'), $.additive)))),
    additive: $ => prec.left(8, seq($.multiplicative, repeat(seq(choice('+', '-'), $.multiplicative)))),
    multiplicative: $ => prec.left(9, seq($.as_expr, repeat(seq(choice('*', '/', '%'), $.as_expr)))),

    // `lvalue as Type` (§3.6a) -- the left operand must be an lvalue in
    // the real language; accepting any unary here is deliberately more
    // lenient, since this grammar is for highlighting, not enforcement.
    as_expr: $ => prec.left(10, seq($.unary, repeat(seq('as', field('type', $.type))))),

    unary: $ => choice(
      seq(choice('!', '-', '*', '&'), $.unary),
      $.postfix
    ),

    postfix: $ => prec(11, seq($.primary, repeat($.postfix_op))),

    postfix_op: $ => choice(
      seq('[', $.expr, ']'),
      seq('.', $.identifier),
      seq('(', optional($.args), ')')
    ),

    primary: $ => choice(
      $.sizeof_expr,
      $.lengthof_expr,
      $.struct_literal,
      $.array_literal,
      $.identifier,
      $.literal,
      seq('(', $.expr, ')')
    ),

    // Compile-time-only (§2.6); the operand can be a type name or an
    // ordinary expression (`sizeof(int32)` vs. `sizeof(x)`) -- both
    // reduce through a bare identifier, hence this pair's own entry in
    // `conflicts` above.
    sizeof_expr: $ => seq('sizeof', '(', choice($.type, $.expr), ')'),
    lengthof_expr: $ => seq('lengthof', '(', choice($.type, $.expr), ')'),

    args: $ => $.expr_list,
    expr_list: $ => seq($.expr, repeat(seq(',', $.expr))),

    // --- LITERALS ---
    struct_literal: $ => seq(
      $.identifier,
      '{',
      $.field_init,
      repeat(seq(',', $.field_init)),
      '}'
    ),

    field_init: $ => seq($.identifier, ':=', $.expr),
    array_literal: $ => seq('{', $.expr_list, '}'),

    literal: $ => choice(
      $.integer_literal,
      $.char_literal,
      $.bool_literal,
      $.null_literal
    ),

    integer_literal: $ => choice(
      token(/\d+n[0-9a-fA-F]+/),
      token(/\d+/)
    ),

    // §1.2: 'a', '\n', '\t', '\r', '\0', '\\', '\''. Fixed type `char`,
    // never an untyped constant (unlike an integer literal).
    char_literal: $ => token(seq(
      "'",
      choice(
        /[^'\\\n]/,
        /\\[ntr0\\']/
      ),
      "'"
    )),

    // Only ever seen as an `@autoload` pattern/path operand (§6.4) --
    // there is no general string type and no other grammar position
    // accepts one.
    string_literal: $ => token(seq('"', /[^"\n]*/, '"')),

    bool_literal: $ => choice('true', 'false'),
    null_literal: $ => 'null',

    // --- TYPES ---
    base_type: $ => choice(
      'int8', 'int16', 'int', 'int32', 'int64',
      'uint8', 'uint16', 'uint', 'uint32', 'uint64',
      'uintptr',
      'bool',
      'char',
      'void',
      $.identifier
    ),

    type: $ => choice(
      $.pointer_type,
      $.array_type,
      seq('(', $.type, ')'),
      $.base_type
    ),

    // Array formation binds tighter (precedence: 2)
    array_type: $ => prec(2, seq($.type, '[', $.integer_literal, ']')),

    // Pointer formation binds looser (precedence: 1)
    pointer_type: $ => prec(1, seq('*', $.type)),

    // --- IDENTIFIERS & COMMENTS ---
    identifier: $ => /[a-zA-Z][a-zA-Z0-9_]*/,

    // Unchanged from v0 -- comments still don't nest here (that's a
    // decided-but-not-yet-implemented v1.1.n change, per
    // docs/postulate_stage1_bootstrap_plan.md; this grammar matches what
    // Edsger_v0 actually lexes today, not the future design).
    comment: $ => choice(
      token(seq('//', /.*/)),
      token(seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/'))
    ),
  }
});
