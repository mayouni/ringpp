# A member read on the right of an assignment is an attribute NAME, not a variable.
# The checker used to report `nHits` below as R24 -- on a program that runs and prints 4, 4.
oBox = new Box
? Peek(oBox)
$oG = new Box
? PeekGlobal()

func Peek(o)
	x = o.nHits
	o.nHits = x + 1
	return o.nHits

func PeekGlobal()
	y = $oG.nHits
	return y + 1

class Box
	nHits = 3
