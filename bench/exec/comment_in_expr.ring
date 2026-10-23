# A COMMENT INSIDE AN EXPRESSION IS NOTHING, as Ring's scanner drops it.
#
# Ring reads a comment anywhere a newline may stand -- between the lines
# of a `+` continuation, among a call's arguments, inside a list literal
# -- and the expression carries on around it. The grammar keeps the
# comment as a node wherever it falls, so a binary expression's second
# named child was the COMMENT and not the right operand, and Ring++
# refused the statement ("comment"). StzUiDocumentQ().ToFixture is that
# shape: eight lines of `#` in the middle of a script built with `+`.
# Every row taken from Ring 1.27 first.

s = "a" +
	# one comment
	"b" +
	# two comments
	// in both styles
	"c"
? "01 across a + continuation: " + s

func main
	? "02 in a function: " + f()
	? "03 among arguments: " + g(1,
		# the second
		2)
	aL = [1,
		# a member
		2, 3]
	? "04 in a list literal: " + len(aL)
	n = 1 +
		/* a block comment */
		2
	? "05 a block comment: " + n
	? "06 a hash inside a string survives: " + ("x" + "#y" +
		# really a comment
		"z")

func f
	c = "p" +
		# inside a function
		"q"
	return c

func g a, b
	return a + b
