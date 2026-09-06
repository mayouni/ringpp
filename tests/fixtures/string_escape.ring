### Fixture for rpp/string-escape (FINDINGS F-55).
###
### Two shapes MUST be reported and two MUST NOT. The two that must not are
### the whole reason the rule is narrow: a literal ending in a backslash is
### an ordinary Windows path, and "line1\nline2" cannot be told apart from
### the path "C:\new" by anything in the source.

func Main()
	# REPORTED: two literals in one expression, each ending in a backslash.
	# Meant to be one string; parses as two and concatenates to a\b\.
	cPair = "a\" + "b\"

	# REPORTED: the literal ended early and left an identifier holding a
	# backslash. R24 at run time, but only when this line is reached.
	? "say \"hi\""

	# NOT reported: an ordinary path that really does end in a separator.
	cPath = "C:\GitHub\"

	# NOT reported: probably a wanted newline, silently a backslash and an n,
	# and indistinguishable from a path. RppStr() is the answer, not a rule.
	cNl = "line1\nline2"

	? cPair + cPath + cNl
