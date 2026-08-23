/**
 * Tree-sitter grammar for the Ring programming language
 *
 * @author Youssef Saeed <youssefelkholey@gmail.com>
 * @license MIT
 * Copyright (c) 2026 Youssef Saeed
 */

/// <reference types="tree-sitter-cli/dsl" />

const PREC = {
	ASSIGN: 1,
	OR: 2,
	AND: 3,
	NOT: 4,
	EQUAL: 5,
	COMPARE: 6,
	BITOR: 7,
	BITXOR: 8,
	BITAND: 9,
	SHIFT: 10,
	ADD: 11,
	MUL: 12,
	RANGE: 13,
	UNARY: 14,
	CALL: 15,
	MEMBER: 16,
};

// Case-insensitive keyword pattern
const ci = (word) =>
	new RegExp(
		word
			.split("")
			.map((c) =>
				/[a-z]/i.test(c) ? `[${c.toLowerCase()}${c.toUpperCase()}]` : c,
			)
			.join(""),
	);

// Ring's scanner treats ANY run of characters that are not operators,
// whitespace or quotes as an identifier — this includes Unicode/Arabic
// identifiers (e.g. عربي) and special names (e.g. @, $var).
const IDENT_CLASS = "[^\\s;\"'`#+*/%.,()=<>!\\[\\]{}:&|~^?-]";
const ident = () => new RegExp(IDENT_CLASS + "+");

// Named keyword rule — keywords win over identifiers (prec 2)
const keyword = (word) => alias(token(prec(2, ci(word))), word);

module.exports = grammar({
	name: "ring",

	extras: ($) => [/[ \t\r\n;]/, $.comment],

	word: ($) => $.identifier,

	externals: ($) => [
		$._func_param_ident,
		$._subscript_open,
		$._demoted_ident,
		$._class_from,
		$._kw_for_to,
		$._kw_for_in,
		$._kw_for_step,
		$._call_lparen,
		$._func_param_open,
	],

	conflicts: ($) => [
		[$.binary_expression, $._stmt_binary_expression],
		[$._package_body],
		[$._class_body],
		[$._func_body],
		[$._expression, $._rhs_expression],
		[$._expression, $._rhs_expression, $._stmt_expression],
		[$._rhs_expression, $._stmt_expression],
		[$._rhs_expression, $._simple_expression],
		[$._expression, $._stmt_expression],
		[$.give_statement, $._primary],
		[$.give_statement, $._rhs_expression],
		[$.postfix_expression, $._stmt_postfix_expression],
		[$.call_expression, $._stmt_call_expression],
		[$.member_expression, $._stmt_member_expression],
		[$.subscript_expression, $._stmt_subscript_expression],
		[$.typed_parameter, $._primary],
		[$.function_definition, $.param_list],
		[$.function_definition],
		[$.function_definition, $.typed_parameter],
		[$.exit_statement],
		[$.return_statement],
		[$.loop_statement],
	],

	rules: {
		// Source file
		source_file: ($) => repeat($._top_level),

		_top_level: ($) =>
			choice(
				$.scanner_command,
				$.package_definition,
				$.class_definition,
				$.function_definition,
				$._statement,
			),

		// Scanner commands
		scanner_command: ($) =>
			choice(
				// The scanner accepts ANY two words as arguments (the new
				// keyword may be an operator or a non-ASCII keyword)
				seq(keyword("changeringkeyword"), /[^\s]+/, /[^\s]+/),
				seq(keyword("changeringoperator"), /[^\s]+/, /[^\s]+/),
				seq(keyword("loadsyntax"), $.string),
				keyword("enablehashcomments"),
				keyword("disablehashcomments"),
			),

		// Packages
		package_definition: ($) =>
			prec.right(
				seq(
					keyword("package"),
					field("name", $.qualified_identifier),
					optional($._package_body),
				),
			),

		_package_body: ($) =>
			choice(
				seq("{", repeat($._package_content), "}"),
				seq(
					repeat1($._package_content),
					optional(choice(keyword("endpackage"), keyword("end"))),
				),
			),

		_package_content: ($) =>
			choice($.package_definition, $.class_definition, $.function_definition, $._statement),

		// Classed
		class_definition: ($) =>
			prec.right(
				seq(
					keyword("class"),
					field("name", choice($.identifier, alias($._demoted_ident, $.identifier))),
					optional(field("parent", $.class_parent)),
					optional($._class_body),
				),
			),

		class_parent: ($) =>
			seq(
				// Ring only accepts `from` for the parent class when it is
				// adjacent to the class name (same line) — on a following
				// line it is demoted to an attribute identifier; the
				// external scanner decides from the newline gap
				choice(alias($._class_from, "from"), token(prec(3, ":")), "<"),
				$.qualified_identifier,
			),

		_class_body: ($) =>
			choice(
				seq("{", repeat($._class_content), "}"),
				seq(
					repeat1($._class_content),
					optional(choice(keyword("endclass"), keyword("end"))),
				),
			),

		_class_content: ($) =>
			prec(1, choice($.class_definition, $.function_definition, $.private_section, $._statement)),

		private_section: ($) =>
			prec.right(seq(keyword("private"), repeat($._class_content))),

		// Functions
		function_definition: ($) =>
			prec.dynamic(
				1,
				choice(
					// With parens (empty or with params) — the opening `(` is scanner-gated
					// (FUNC_PARAM_OPEN) so that a parenthesized expression can
					// never compete with the parameter list (GLR tie)
					prec.dynamic(
						1,
						seq(
							$._func_keyword,
							field("name", choice($.identifier, alias($._demoted_ident, $.identifier))),
							$._func_param_open,
							optional(field("parameters", $.param_list)),
							")",
							optional($._func_body),
						),
					),
					// With params without parens (external scanner gates this —
					// only matches when the first param is adjacent to the name)
					seq(
						$._func_keyword,
						field("name", choice($.identifier, alias($._demoted_ident, $.identifier))),
						field("parameters", alias($.func_params_no_parens, $.param_list)),
						optional($._func_body),
					),
					// No params
					seq(
						$._func_keyword,
						field("name", choice($.identifier, alias($._demoted_ident, $.identifier))),
						optional($._func_body),
					),
				),
			),

		func_params_no_parens: ($) =>
			seq(
				// The first parameter must be adjacent to the named
				// function (provided by the external scanner) — this
				// separates the parameter list from the next statement
				alias($._func_param_ident, $.identifier),
				repeat(
					seq(
						",",
						choice(
							$.identifier,
							alias($._demoted_ident, $.identifier),
						),
					),
				),
			),

		param_list: ($) =>
			commaSep(
				choice(
					$.identifier,
					alias($._demoted_ident, $.identifier),
					$.typed_parameter,
				),
			),

		// Typed parameter (`func sum(int x, int y)` — type is skipped by the
		// Ring parser but kept here so the structure is visible)
		typed_parameter: ($) =>
			seq(field("type", $.identifier), field("name", choice($.identifier, alias($._demoted_ident, $.identifier)))),

		/*
		 * Statements allowed inside a function/package/class body.
		 * Excludes definition keywords (func/class/package) to prevent
		 * a function body from consuming the next definition.
		 */
		_body_statement: ($) =>
			seq(
				choice(
					$.if_statement,
					$.while_statement,
					$.for_statement,
					$.do_again_statement,
					$.switch_statement,
					$.try_statement,
					$.load_statement,
					$.import_statement,
					$.see_statement,
					$.give_statement,
					$.return_statement,
					$.exit_statement,
					$.loop_statement,
					$.bye_statement,
					$.expression_statement,
				),
				optional(","),
			),

		_func_body: ($) =>
			prec.dynamic(
				2,
				choice(
					seq("{", repeat($._body_statement), "}"),
					seq(repeat1($._body_statement), optional($._func_end)),
				),
			),

		_func_keyword: ($) =>
			choice(keyword("func"), keyword("function"), keyword("def")),

		_func_end: ($) =>
			choice(keyword("endfunc"), keyword("endfunction"), keyword("end")),

		// Statements
		_statement: ($) =>
			seq(
				choice(
					$.if_statement,
					$.while_statement,
					$.for_statement,
					$.do_again_statement,
					$.switch_statement,
					$.try_statement,
					$.load_statement,
					$.import_statement,
					$.see_statement,
					$.give_statement,
					$.return_statement,
					$.exit_statement,
					$.loop_statement,
					$.bye_statement,
					$.expression_statement,
				),
				// a comma separates statements on the same line
				optional(","),
			),

		if_statement: ($) =>
			prec.right(
				seq(
					keyword("if"),
					field("condition", $._simple_expression),
					optional(token(prec(PREC.MEMBER + 1, "{"))),
					repeat($._statement),
					repeat($.elseif_clause),
					optional($.else_clause),
					$._if_end,
				),
			),

		elseif_clause: ($) =>
			seq(
				choice(keyword("but"), keyword("elseif")),
				$._expression,
				repeat($._statement),
			),

		else_clause: ($) =>
			seq(choice(keyword("else"), keyword("other")), repeat($._statement)),

		_if_end: ($) =>
			choice(keyword("ok"), keyword("end"), keyword("endif"), "}"),

		while_statement: ($) =>
			prec.right(
				seq(
					keyword("while"),
					$._simple_expression,
					optional(token(prec(PREC.MEMBER + 1, "{"))),
					repeat($._statement),
					choice(keyword("end"), keyword("endwhile"), "}"),
				),
			),

		for_statement: ($) =>
			prec.right(
				seq(
					choice(keyword("for"), keyword("foreach")),
					field(
						"variable",
						choice(
							$.identifier,
							alias($._demoted_ident, $.identifier),
						),
					),
					choice(
						seq(
							"=",
							$._simple_expression,
							alias($._kw_for_to, "to"),
							$._simple_expression,
						),
						seq(alias($._kw_for_in, "in"), $._simple_expression),
					),
					optional(
						seq(alias($._kw_for_step, "step"), $._simple_expression),
					),
					optional(token(prec(PREC.MEMBER + 1, "{"))),
					repeat($._statement),
					choice(keyword("next"), keyword("end"), keyword("endfor"), "}"),
				),
			),

		do_again_statement: ($) =>
			seq(
				keyword("do"),
				repeat($._statement),
				keyword("again"),
				$._simple_expression,
			),

		switch_statement: ($) =>
			prec.right(
				seq(
					keyword("switch"),
					$._simple_expression,
					optional(token(prec(PREC.MEMBER + 1, "{"))),
					repeat($.case_clause),
					optional($.other_clause),
					choice(keyword("off"), keyword("end"), keyword("endswitch"), "}"),
				),
			),

		case_clause: ($) =>
			seq(
				choice(keyword("on"), keyword("case")),
				$._expression,
				repeat($._statement),
			),

		other_clause: ($) =>
			seq(choice(keyword("other"), keyword("else")), repeat($._statement)),

		try_statement: ($) =>
			prec.right(
				seq(
					keyword("try"),
					optional("{"),
					repeat($._statement),
					$.catch_clause,
					choice(keyword("done"), keyword("end"), keyword("endtry"), "}"),
				),
			),

		catch_clause: ($) =>
			seq(
				keyword("catch"),
				repeat($._statement),
			),

		load_statement: ($) =>
			seq(
				keyword("load"),
				optional(choice(keyword("package"), keyword("again"))),
				$.string,
			),

		import_statement: ($) => seq(keyword("import"), $.qualified_identifier),

		see_statement: ($) =>
			seq(choice(keyword("see"), keyword("put"), "?"), $._expression),

		give_statement: ($) =>
			seq(choice(keyword("give"), keyword("get")), choice($.identifier, $.member_expression, $.subscript_expression)),

		return_statement: ($) =>
			choice(
				keyword("return"),
				// Dynamic precedence keeps `return <expr>` together — bare
				// `return` is only used when no expression follows
				prec.dynamic(
					1,
					seq(keyword("return"), optional("&"), $._simple_expression),
				),
			),

		exit_statement: ($) =>
			choice(
				choice(keyword("exit"), keyword("break")),
				// Dynamic precedence keeps `exit <expr>` together — bare
				// `exit`/`break` is only used when no expression follows
				prec.dynamic(
					1,
					seq(choice(keyword("exit"), keyword("break")), $._simple_expression),
				),
			),

		loop_statement: ($) =>
			choice(
				choice(keyword("loop"), keyword("continue")),
				// Dynamic precedence keeps `loop <expr>` together — bare
				// `loop`/`continue` is only used when no expression follows
				prec.dynamic(
					1,
					seq(
						choice(keyword("loop"), keyword("continue")),
						$._simple_expression,
					),
				),
			),

		bye_statement: ($) => keyword("bye"),

		expression_statement: ($) => $._stmt_expression,

		// Expressions
		_expression: ($) =>
			choice(
				$.assignment_expression,
				$.binary_expression,
				$.unary_expression,
				$.postfix_expression,
				$.call_expression,
				$.call_keyword_expression,
				$.member_expression,
				$.subscript_expression,
				$.brace_expression,
				$.new_expression,
				$.anonymous_function,
				$.parenthesized_expression,
				$._primary,
			),

		// Simple expression - excludes brace_expression and assignment_expression
		// (for control structure conditions). In Ring, `=` in conditions is always
		// equality comparison, never assignment.
		_simple_expression: ($) =>
			choice(
				$.binary_expression,
				$.unary_expression,
				$.postfix_expression,
				$.call_expression,
				$.call_keyword_expression,
				$.member_expression,
				$.subscript_expression,
				$.new_expression,
				$.anonymous_function,
				$.parenthesized_expression,
				$._primary,
			),

		// Expression for the RHS of assignment — excludes assignment itself
		// so that chained assignment is impossible. Ring sets lAssignmentFlag=0
		// when parsing the RHS, which turns `=` into equality. Here, the
		// absence of assignment_expression in this choice means `=` on the RHS
		// falls through to binary_expression's equality rule (PREC.EQUAL),
		// giving `a = b = c` the Ring semantics: `a = (b == c)`.
		_rhs_expression: ($) =>
			choice(
				$.binary_expression,
				$.unary_expression,
				$.postfix_expression,
				$.call_expression,
				$.call_keyword_expression,
				$.member_expression,
				$.subscript_expression,
				$.brace_expression,
				$.new_expression,
				$.anonymous_function,
				$.parenthesized_expression,
				$._primary,
			),



		assignment_expression: ($) =>
			prec.left(
				PREC.ASSIGN,
				seq(
					$._expression,
					choice(
						"=",
						"+=",
						"-=",
						"*=",
						"/=",
						"%=",
						"&=",
						"|=",
						"^=",
						"<<=",
						">>=",
						"**=",
						"^^=", // Ring scans ^^ as the power operator
					),
					$._rhs_expression,
				),
			),

		// Same as assignment_expression, but the left hand side can never
		// begin with `func` (used for statement-initial expressions).
		// Dynamic precedence 4 keeps bare `=` as assignment at statement
		// level, beating the binary `x != 0`-style parses (dynamic 3).
		_stmt_assignment_expression: ($) =>
			prec.dynamic(
				4,
				prec.left(
					PREC.ASSIGN,
					seq(
						$._stmt_expression,
						choice(
							"=",
							"+=",
							"-=",
							"*=",
							"/=",
							"%=",
							"&=",
							"|=",
							"^=",
							"<<=",
							">>=",
							"**=",
							"^^=",
						),
						$._rhs_expression,
					),
				),
			),

		binary_expression: ($) =>
			// Dynamic precedence 3 — above _func_body's 2, so a joined
			// binary parse strictly outweighs any parse that splits `+`/`-`
			// into a new unary statement, even when a competing version
			// joins a binary elsewhere (GLR sums precedence per version).
			prec.dynamic(
				3,
				choice(
					prec.left(
						PREC.OR,
						seq($._rhs_expression, choice(keyword("or"), "||"), $._rhs_expression),
					),
					prec.left(
						PREC.AND,
						seq($._rhs_expression, choice(keyword("and"), "&&"), $._rhs_expression),
					),
					prec.left(
						PREC.EQUAL,
						seq($._rhs_expression, choice("=", "!="), $._rhs_expression),
					),
					prec.left(
						PREC.COMPARE,
						seq($._rhs_expression, choice("<", ">", "<=", ">="), $._rhs_expression),
					),
					prec.left(PREC.BITOR, seq($._rhs_expression, choice("|", "^"), $._rhs_expression)),
					prec.left(PREC.BITAND, seq($._rhs_expression, "&", $._rhs_expression)),
					prec.left(
						PREC.SHIFT,
						seq($._rhs_expression, choice("<<", ">>"), $._rhs_expression),
					),
					prec.left(
						PREC.ADD,
						seq($._rhs_expression, choice("+", "-"), $._rhs_expression),
					),
					prec.left(
						PREC.MUL,
						seq(
							$._rhs_expression,
							choice("*", "/", "%", "**", "^^"),
							$._rhs_expression,
						),
					),
					prec.left(PREC.RANGE, seq($._rhs_expression, ":", $._rhs_expression)),
				),
			),

		// Same as binary_expression, but the operands can never begin with
		// `func` (used for statement-initial expressions). The dynamic
		// precedence (3, same as binary_expression) makes the joined binary
		// parse beat the split alternative (identifier statement + unary
		// +/- statement).
		_stmt_binary_expression: ($) =>
			prec.dynamic(
				3,
				choice(
					prec.left(
						PREC.OR,
						seq($._rhs_expression, choice(keyword("or"), "||"), $._rhs_expression),
					),
					prec.left(
						PREC.AND,
						seq($._rhs_expression, choice(keyword("and"), "&&"), $._rhs_expression),
					),
					prec.left(
						PREC.EQUAL,
						seq($._rhs_expression, "!=", $._rhs_expression),
					),
					prec.left(
						PREC.COMPARE,
						seq($._rhs_expression, choice("<", ">", "<=", ">="), $._rhs_expression),
					),
					prec.left(PREC.BITOR, seq($._rhs_expression, choice("|", "^"), $._rhs_expression)),
					prec.left(PREC.BITAND, seq($._rhs_expression, "&", $._rhs_expression)),
					prec.left(
						PREC.SHIFT,
						seq($._rhs_expression, choice("<<", ">>"), $._rhs_expression),
					),
					prec.left(
						PREC.ADD,
						seq($._rhs_expression, choice("+", "-"), $._rhs_expression),
					),
					prec.left(
						PREC.MUL,
						seq(
							$._rhs_expression,
							choice("*", "/", "%", "**", "^^"),
							$._rhs_expression,
						),
					),
					prec.left(PREC.RANGE, seq($._rhs_expression, ":", $._rhs_expression)),
				),
			),

		unary_expression: ($) =>
			prec.right(
				PREC.UNARY,
				seq(choice("-", "+", "~", "!", keyword("not")), $._expression),
			),

		postfix_expression: ($) =>
			prec.left(PREC.CALL, seq(choice($.identifier, $.member_expression, $.subscript_expression), choice("++", "--"))),

		_stmt_postfix_expression: ($) =>
			prec.left(PREC.CALL, seq(choice($.identifier, $.member_expression, $.subscript_expression), choice("++", "--"))),

		// The `call` keyword — used as an expression to call an anonymous
		// function or execute a block (ring_parser_factor in
		// language/src/expr.c). NOT a statement — K_CALL is never checked
		// in ring_parser_stmt.
		call_keyword_expression: ($) =>
			seq(keyword("call"), choice($._expression, $.brace_block)),

		// The `(` of a call must sit on the same line as the callee: Ring's
		// parser checks for OP_FOPEN without skipping the EndLine token
		// (ring_parser_mixer in language/src/expr.c), so
		// `x = y` + newline + `(expr)` is two statements, never a call.
		// The external scanner skips newlines only while a mixer chain is
		// open (last token was `[`/`(`), which keeps
		// call-vs-parenthesized-statement deterministic.
		call_expression: ($) =>
			prec(
				PREC.CALL,
				seq(
					choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression),
					alias($._call_lparen, "("),
					optional($.arguments),
					")",
				),
			),

		_stmt_call_expression: ($) =>
			prec(
				PREC.CALL,
				seq(
					choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression),
					alias($._call_lparen, "("),
					optional($.arguments),
					")",
				),
			),

		brace_block: ($) => seq("{", repeat($._statement), "}"),

		arguments: ($) => prec.left(commaSep($._expression)),

		member_expression: ($) =>
			prec.left(
				PREC.MEMBER,
				seq(
					choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression, $.brace_expression, $.new_with_parens, $.parenthesized_expression, $.self, $.super),
					".",
					choice($.identifier, alias($._demoted_ident, $.identifier), $.string),
				),
			),

		_stmt_member_expression: ($) =>
			prec.left(
				PREC.MEMBER,
				seq(
					choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression, $.brace_expression, $.new_with_parens, $.parenthesized_expression, $.self, $.super),
					".",
					choice($.identifier, alias($._demoted_ident, $.identifier), $.string),
				),
			),

		subscript_expression: ($) =>
			prec.left(
				PREC.CALL,
				seq(choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression, $.new_expression, $.self, $.super), $._subscript_open, $._expression, "]"),
			),

		_stmt_subscript_expression: ($) =>
			prec.left(
				PREC.CALL,
				seq(choice($.identifier, alias($._demoted_ident, $.identifier), $.member_expression, $.subscript_expression, $.call_expression, $.new_expression, $.self, $.super), $._subscript_open, $._expression, "]"),
			),

		brace_expression: ($) =>
			prec(PREC.CALL, seq($._expression, "{", repeat($._statement), "}")),

		_stmt_brace_expression: ($) =>
			prec(PREC.CALL, seq($._stmt_expression, "{", repeat($._statement), "}")),

		// Statement-initial expressions: like $._expression but WITHOUT
		// anonymous functions — a statement can never begin with `func`.
		// This is what lets an empty/missing function body end cleanly when
		// the next `func`/`def`/`function` keyword appears.
		_stmt_expression: ($) =>
			choice(
				alias($._stmt_assignment_expression, $.assignment_expression),
				alias($._stmt_binary_expression, $.binary_expression),
				$.unary_expression,
				$.new_expression,
				$.parenthesized_expression,
				$.call_keyword_expression,
				alias($._stmt_postfix_expression, $.postfix_expression),
				alias($._stmt_call_expression, $.call_expression),
				alias($._stmt_member_expression, $.member_expression),
				alias($._stmt_subscript_expression, $.subscript_expression),
				alias($._stmt_brace_expression, $.brace_expression),
				$.anonymous_function,
				$._primary,
			),

		// prec.right(PREC.MEMBER): ties with the member/shift rules' . token
		// so the shift wins and `new pkg.class` keeps its qualified name
		// (the constructor parens `(` shift also ties — same rule — and
		// wins). Chains like `new X().method` attach AFTER the whole
		// new_expression (its object in member/call/subscript).
		new_expression: ($) =>
			prec.right(
				PREC.MEMBER,
				seq(
					keyword("new"),
					optional(keyword("from")),
					$.qualified_identifier,
					optional(
						choice(
							// Constructor-call parens obey the same
							// same-line rule as call_expression
							// (OP_FOPEN is checked without skipping
							// the EndLine)
							seq(
								alias($._call_lparen, "("),
								optional($.arguments),
								")",
							),
							// The brace form ignores newlines
							// (OP_BRACEOPEN is checked after
							// RING_PARSER_IGNORENEWLINE)
							seq("{", repeat($._statement), "}"),
						),
					),
				),
			),

		// The parens-bearing constructor is the ONLY chainable new form
		// (Ring's mixer can follow it, and `new pkg.Class` must keep its
		// qualified name). Keeping the parens OUT of member_expression's
		// object makes `new X.Y` unambiguous: the bare new_expression has
		// no `.` continuation, so only the qualified path survives.
		new_with_parens: ($) =>
			prec.right(
				PREC.MEMBER,
				seq(
					keyword("new"),
					optional(keyword("from")),
					$.qualified_identifier,
					alias($._call_lparen, "("),
					optional($.arguments),
					")",
				),
			),

		anonymous_function: ($) =>
			seq(
				$._func_keyword,
				optional(
					choice(seq("(", ")"), seq("(", $.param_list, ")"), $.param_list),
				),
				"{",
				repeat($._statement),
				"}",
			),

		parenthesized_expression: ($) =>
			prec(PREC.CALL, seq("(", optional($._expression), ")")),

		// Primary
		_primary: ($) =>
			choice(
				$.identifier,
				// Ring demotes the keywords to/in/from/step back to
				// identifiers whenever the parser is at an identifier
				// position (ring_parser_processkeywords in
				// language/src/parser.c) — the external scanner emits this
				// token only when it is valid in the current state
				alias($._demoted_ident, $.identifier),
				$.number,
				$.string,
				$.list_literal,
				$.symbol,
				$.self,
				$.super,
				$.boolean,
				$.null,
			),

		// Ring's scanner accumulates the entire word, then classifies it
		// as keyword / number / identifier (ring_scanner_checktoken,
		// scanner.c:261). A word like `3Copies` fails ring_scanner_isnumber
		// and becomes a single IDENTIFIER; `42` passes and becomes NUMBER.
		// (Floats differ: `.` is an operator, so `3.14` is NUMBER+`.`+
		// NUMBER, merged later by ring_scanner_floatmark.)
		//
		// Tree-sitter can't read whole words — it matches regexes
		// char-by-char. Its lexical resolution is: (1) lexical precedence,
		// (2) match length, (3) declaration order. Both tokens here are
		// at default precedence (0), so step 1 is a no-op. Moving `number`
		// before `identifier` makes step 3 break ties in favour of
		// `number` (pure numbers like `42`, `0xFF`), while step 2 lets
		// longer identifier runs (`3Copies`) win by match length —
		// producing the same outcome as Ring's whole-word classification.
		number: ($) =>
			token(
				choice(
					/0+[xX][0-9a-fA-F](_*[0-9a-fA-F])*/,
					/[0-9](_*[0-9])*\.[0-9](_*[0-9])*[fF]?/,
					/[0-9](_*[0-9])*[fF]?/,
				),
			),

		identifier: ($) => ident(),

		qualified_identifier: ($) =>
			prec.left(seq($.identifier, repeat(seq(".", $.identifier)))),

		string: ($) =>
			choice($._string_double, $._string_single, $._string_backtick),

		_string_double: ($) =>
			seq(
				'"',
				repeat(
					choice(
						$._string_content_double,
						$._string_hash_double,
						$.interpolation,
					),
				),
				token.immediate('"'),
			),

		_string_content_double: ($) => token.immediate(prec(1, /[^"#]+/)),
		_string_hash_double: ($) => token.immediate(prec(1, /#/)),

		_string_single: ($) =>
			seq(
				"'",
				repeat(
					choice(
						$._string_content_single,
						$._string_hash_single,
						$.interpolation,
					),
				),
				token.immediate("'"),
			),

		_string_content_single: ($) => token.immediate(prec(1, /[^'#]+/)),
		_string_hash_single: ($) => token.immediate(prec(1, /#/)),

		_string_backtick: ($) =>
			seq(
				"`",
				repeat(
					choice(
						$._string_content_backtick,
						$._string_hash_backtick,
						$.interpolation,
					),
				),
				token.immediate("`"),
			),

		_string_content_backtick: ($) => token.immediate(prec(1, /[^`#]+/)),
		_string_hash_backtick: ($) => token.immediate(prec(1, /#/)),

		interpolation: ($) =>
			seq(token.immediate("#{"), repeat($._statement), "}"),

		// Colon-prefixed literal (`:name`, `:123`, `:see`) — expr.c accepts
		// any identifier, keyword or number after the colon. A `:` can only
		// start a symbol where no left operand exists, so `1:5` ranges and
		// `aList[:1]` indices are unambiguous.
		symbol: ($) => prec(3, seq(":", choice($.identifier, $.number, alias($._demoted_ident, $.identifier)))),

		list_literal: ($) =>
			seq(
				"[",
				optional(
					seq($._list_item, repeat(seq(",", $._list_item)), optional(",")),
				),
				"]",
			),

		_list_item: ($) => choice($.hash_pair, $._expression),

		hash_pair: ($) =>
			// dynamic 5 keeps hash pairs beating the binary-equality parse
			// of `key = value` inside list literals (binary has dynamic 3)
			prec.dynamic(
				5,
				prec(
					2,
					seq(choice($.symbol, $.identifier, $.string), "=", $._expression),
				),
			),

		// Specials
		self: ($) => choice(keyword("self"), keyword("this")),
		super: ($) => keyword("super"),
		// Not Ring keywords (they are pre-initialized variables), but given
		// their own node type so editor queries can highlight them.
		boolean: ($) => choice(keyword("true"), keyword("false")),
		null: ($) => keyword("null"),

		// Comments
		comment: ($) =>
			token(
				choice(
					seq("#", /[^\n]*/),
					seq("//", /[^\n]*/),
					seq("/*", /[^*]*\*+([^/*][^*]*\*+)*/, "/"),
				),
			),
	},
});

function commaSep(rule) {
	return seq(rule, repeat(seq(",", rule)));
}