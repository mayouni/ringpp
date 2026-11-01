# RUNG 7's class, as first admitted: a tally that holds its total. The
# host reaches it through a function -- a `new Tally` the host compiled
# before Tally existed would be R11 (rung 4's note)
func MakeTally
	return new Tally

class Tally
	nTotal = 0
	def Add n
		nTotal += n
	def Total
		return nTotal
