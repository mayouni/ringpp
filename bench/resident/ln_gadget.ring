# RUNG 8: the classes ln_host.ring wrote `new` for before any file defined
# them. Gadget has no init; Widget's takes one argument.
? "gadget: its top level runs"

func GadgetCount
	return 2

class Gadget
	nX = 1
	cName = "g"

	def Bump
		nX++

	def SetX n
		nX = n

class Widget
	cLabel = "-"

	def init x
		if isObject(x)
			cLabel = "self:" + classname(x)
		else
			cLabel = "w:" + x
		ok

	def Label
		return cLabel
