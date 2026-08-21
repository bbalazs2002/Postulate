module.exports = grammar({
  name: 'postulate',

  extras: $ => [
    /\s/,
    $.comment,
  ],

  conflicts: $ => [
    [$.type, $.primary],
    [$.primary, $.struct_literal],
    [$.lvalue, $.primary]
  ],

  rules: {
    program: $ => repeat1($.top_level_decl),

    top_level_decl: $ => choice(
      $.function,
      $.struct_decl,
      $.extern_decl
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

    return_type: $ => choice($.type, 'void'),

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

    // --- EXPRESSIONS (Precedencia léptetés) ---
    expr: $ => $.logic_or,

    logic_or: $ => prec.left(1, seq($.logic_and, repeat(seq('||', $.logic_and)))),
    logic_and: $ => prec.left(2, seq($.comparison, repeat(seq('&&', $.comparison)))),
    comparison: $ => prec.left(3, seq($.bit_or, optional(seq(choice('==', '!=', '<', '>', '<=', '>='), $.bit_or)))),
    bit_or: $ => prec.left(4, seq($.bit_xor, repeat(seq('|', $.bit_xor)))),
    bit_xor: $ => prec.left(5, seq($.bit_and, repeat(seq('^', $.bit_and)))),
    bit_and: $ => prec.left(6, seq($.shift, repeat(seq('&', $.shift)))),
    shift: $ => prec.left(7, seq($.additive, repeat(seq(choice('<<', '>>'), $.additive)))),
    additive: $ => prec.left(8, seq($.multiplicative, repeat(seq(choice('+', '-'), $.multiplicative)))),
    multiplicative: $ => prec.left(9, seq($.unary, repeat(seq(choice('*', '/', '%'), $.unary)))),

    unary: $ => choice(
      seq(choice('!', '-', '*', '&'), $.unary),
      $.postfix
    ),

    postfix: $ => prec(10, seq($.primary, repeat($.postfix_op))),

    postfix_op: $ => choice(
      seq('[', $.expr, ']'),
      seq('.', $.identifier),
      seq('(', optional($.args), ')')
    ),

    primary: $ => choice(
      $.struct_literal,
      $.array_literal,
      $.identifier,
      $.literal,
      seq('(', $.expr, ')')
    ),

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
      $.bool_literal,
      $.null_literal
    ),

    integer_literal: $ => choice(
      token(/\d+n[0-9a-fA-F]+/), // based_form (pl. 10n11)
      token(/\d+/)               // decimal_form
    ),

    bool_literal: $ => choice('true', 'false'),
    null_literal: $ => 'null',

    // --- TYPES ---
    base_type: $ => choice(
      'int8', 'int16', 'int', 'int32', 'int64',
      'uint8', 'uint16', 'uint', 'uint32', 'uint64',
      'bool',
      $.identifier
    ),

    type: $ => choice(
      seq('*', $.base_type, '[', $.integer_literal, ']'),
      seq('*', $.type),
      seq($.base_type, '[', $.integer_literal, ']'),
      seq('(', $.type, ')'),
      $.base_type
    ),

    // --- IDENTIFIERS & COMMENTS ---
    identifier: $ => /[a-zA-Z_][a-zA-Z0-9_]*/,

    comment: $ => choice(
      token(seq('//', /.*/)),
      token(seq('/*', /[^*]*\*+([^/*][^*]*\*+)*/, '/'))
    ),
  }
});