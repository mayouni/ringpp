# `#rpp: default`, all four directions for the CHECKER. Exactly three must
# fire, and the well-formed one must stay silent -- the count is the proof.

# MUST STAY SILENT: trailing defaults, every name a parameter, every one
# with a value.
func Good(a, b, c)   #rpp: default b = 2, c = "x"
	return a

# MUST FIRE: bb is not a parameter. A typo here would otherwise be honoured
# as silence while the call sites went on raising R19.
func Typo(a, b)   #rpp: default bb = 2
	return a

# MUST FIRE: b has a default and c does not. Arguments are positional, so
# Middle(1) cannot say which of b or c it meant to skip.
func Middle(a, b, c)   #rpp: default b = 2
	return a

# MUST FIRE: a name with no value cannot be filled in anywhere.
func NoVal(a, b)   #rpp: default b
	return a
