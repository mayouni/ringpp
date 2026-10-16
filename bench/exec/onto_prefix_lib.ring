# The "library" half of onto_prefix.ring: its top level runs first, and
# what it defines is what the file compiled on top has to reach.

$libGlobal = 100
? "library top level ran first"

func LibDouble n
	return n * 2

# eval INSIDE A LIBRARY FUNCTION (F-72): the string binds to this frame's
# local and parameter, and names a new local the code below reads. On the
# prefix path the frame is known only through what the prefix carries.
func LibEvalLocal p
	n = 5
	eval("n = n + p")
	eval("fresh = n * 2")
	return "" + n + " " + fresh

class LibThing
	nHeld = 0

	def Set_(n)
		nHeld = n

	def Twice()
		return nHeld * 2

	def ViaEval()
		eval("nHeld = nHeld + 1")
		eval("t = Twice()")
		return "" + nHeld + " " + t
