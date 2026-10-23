# Ring binds `not` and `!` looser than a comparison or arithmetic (not_precedence.ring), and an OBJECT's class is told the operator the
# SOURCE wrote: `not o = p` calls operator("=") and negates its answer, `not o + p` calls operator("+"), and `(not o) = p` -- which is
# not here: rnxc does not call operator("not") on an object, a separate defect -- would call "not" first. Kept apart from
# not_precedence.ring because a class with an `operator` method is a construct the Python-shaped face refuses, and that probe is the one the
# face can spell, print, read back and run on the oracle (haro stage 26).

o = new K
p = new K
? "o = p"
? not o = p
? "o + p"
? not o + p
? "o < 3 and 1"
? not o < 3 and 1


class K
	func operator cOp, v
		? "   op " + cOp
		return 0
