# Case 1 of ysdragon/tree-sitter-ring issue #2 -- digit-leading identifiers
# in argument position. ONE case per file, because a whole-file verdict cannot
# say WHICH line the grammar refused.
#
# Ring accepts all four cases. The grammar vendored at 65b185e rejected only
# case 4. v1.1.1 (287afffb) is meant to accept case 4 and leave 1-3 alone.
#
# Parsed, never run: 3Copies and Wrap are Softanza names, undefined here.
# `ring <file> -norun` compiles without executing, so nothing is ever called.
#
# Statement level, digit-leading identifier.
# Before the fix: ACCEPTED

func Main
	? 3Copies("x")
