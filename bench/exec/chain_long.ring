# A LONG CALL CHAIN IN STATEMENT POSITION. The grammar cuts a chain of nine
# calls after its first link -- `IsQ().` and a bare `TheQ()...` -- and the
# bare call bound the global function TheQ(p) and raised R19, where Ring runs
# the chain (nnl_narrated.ring:298, Softanza's question frames). Eight links
# parse whole, and so does the same chain as an assignment's value; rows 2
# and 3 are those controls. Ring++ re-reads the statement in parentheses.

$nOrNot = 0
IsQ().TheQ().LengthQ().OfQ("Ring").TheSameAsQ().TheQ().LengthQ().OfQ("Ruby").OrNot()
? "1 nine links as a statement ran, OrNot answered " + $nOrNot
IsQ().TheQ().LengthQ().OfQ("Ring").TheSameAsQ().TheQ().LengthQ().OfQ("Ruby")
? "2 eight links as a statement ran"
x = IsQ().TheQ().LengthQ().OfQ("Ring").TheSameAsQ().TheQ().LengthQ().OfQ("Ruby").OrNot()
? "3 nine links as a value: " + x
IsQ().TheQ().LengthQ().OfQ("Ring").TheSameAsQ().TheQ().LengthQ().OfQ("Ruby").TheQ().LengthQ().OfQ("x").OrNot()
? "4 twelve links as a statement ran, OrNot answered " + $nOrNot

func IsQ()
	return new K

func TheQ(p)
	return p

class K
	def TheQ()
		return This
	def LengthQ()
		return This
	def OfQ(p)
		return This
	def TheSameAsQ()
		return This
	def OrNot()
		$nOrNot++
		return 1
