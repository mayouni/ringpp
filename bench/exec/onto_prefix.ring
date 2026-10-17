# The shape a PREFIX can be used for: the load comes FIRST, and everything
# this file does comes after it. The library half declares a function, a
# class with a method and an attribute, and a global -- the four things a
# file compiled on top has to be able to reach across the boundary.
#
# load_order.ring is the opposite case, and it is the one that made the
# check exact: a file that prints before it loads cannot be split this way,
# because Ring runs the loaded top level AT the load statement.

load "onto_prefix_lib.ring"

? "main after the load"
? "lib global      : " + $libGlobal
? "lib function    : " + LibDouble(21)
oT = new LibThing
oT.Set_(7)
? "lib method      : " + oT.Twice()
? "lib attribute   : " + oT.nHeld
? "lib eval        : " + LibEvalLocal(10)
? "lib eval method : " + oT.ViaEval()
? "own function    : " + OwnTriple(5)
oM = new OwnThing
? "own class       : " + oM.Say()
? "own calls lib   : " + oM.ViaLib(4)
oC = new OwnChild
? "child of lib    : " + oC.Show()
oB = new OwnBare
? "bare child      : " + oB.Show()

func OwnTriple n
	return n * 3

class OwnThing
	def Say()
		return "own thing"

	def ViaLib(n)
		return LibDouble(n) + $libGlobal

# a library class's child, with initialisers of its own and without
class OwnChild from LibMid
	cOwn = "own"

	def Show()
		return cKind + " " + nCount + " " + cMid + " " + cOwn

class OwnBare from LibMid
	def Show()
		return cKind + " " + nCount + " " + cMid
