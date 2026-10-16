# `&&` and `||` are Ring's `and` and `or`: the grammar offers them as
# alternatives of the same rule and Ring's parser reads them alike, so they
# yield 1 or 0 and short-circuit exactly as the words do. rnxc compared the
# operator's text with "and" and "or" only and REFUSED `a && b` as an
# unsupported binary expression (the program stopped at that line).
# Measured on the oracle and on the official 1.27, which agree on every row.

a = 1
b = 0
? "a && b       = " + (a && b)
? "a || b       = " + (a || b)
? "a and b      = " + (a and b)
? "a or b       = " + (a or b)
? "1 && 1 || 0  = " + (1 && 1 || 0)
? "0 || 0 && 1  = " + (0 || 0 && 1)
? "0 || 1 && 1  = " + (0 || 1 && 1)
? "!a           = " + (!a)
? "!b           = " + (!b)
? "not a        = " + (not a)

if a && b
	? "if a && b: taken"
else
	? "if a && b: not taken"
ok

if a || b
	? "if a || b: taken"
else
	? "if a || b: not taken"
ok

x = 5
? "range         = " + (x > 3 && x < 9)
? "either        = " + (x > 3 || x < 0)
while x > 3 && x < 8
	x++
end
? "while ended at " + x

# short-circuit: the right side is not evaluated when the left decides
# (the function comes last: whatever follows a `func` is part of its flow)
? "short and     = " + (0 && Boom())
? "short or      = " + (1 || Boom())

func Boom()
	? "BOOM ran"
	return 1
