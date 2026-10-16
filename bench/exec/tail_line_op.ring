# F-114 again, through an `operator` method: the frame that called it is
# reported at the line of the token after the statement -- the `ok` that
# closes the if, not the line the statement is on.
aL = ["abc"]
o = new K
if 1
	x = o + aL[1]
ok
? "next"

class K
	def operator cOp, v
		raise("operator " + cOp)
