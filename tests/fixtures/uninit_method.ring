# rpp/uninitialized-variable INSIDE a class method, both directions.
#
# F-47 kept the rule out of class bodies because a method reads attributes
# and inherited state the pass does not model. That holds for a BARE name
# and says nothing about a `$` one: `$x` in Ring is a global, never an
# attribute and never inherited, and absence is already proven set-wide.
#
# This file is a COMPLETE universe on purpose -- no load, no eval, no
# loadlib -- because the rule only speaks when it can see everything.

func main
	o = new T
	? o.Go("ab")

class T
	aAttr = []
	@cName = ""

	# MUST FIRE: nothing anywhere assigns $_nMissing_, so the read is R24.
	# It sits on the THIRD body statement, which the vendored grammar emits
	# as a sibling of the class rather than a child of the method -- so a
	# subtree walk would miss it and this gate would pass for the wrong
	# reason.
	def Go(pcStr)
		nOk = len(pcStr)
		nOk = nOk + 1
		return nOk + $_nMissing_

	# MUST STAY SILENT: a bare unknown name inside a method could be an
	# attribute of a parent this pass does not model.
	def Silent(pcStr)
		return len(_cUnknown_)

	# MUST STAY SILENT: the attribute declared above, and the @ form.
	def Fine()
		aAttr + 1
		return len(aAttr) + len(@cName)
