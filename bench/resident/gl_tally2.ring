# Tally REPLACED with three attributes it did not have: the objects made
# before take them, starting as declared -- the list a list of their own
class Tally
	nTotal = 0
	nAdds = 0
	aTags = []
	cNote
	def Add n
		nTotal += n
		nAdds++
	def Tag c
		aTags + c
	def SetNote c
		cNote = c
	def Summary
		return "" + nTotal + " in " + nAdds + " add(s), tags " + len(aTags) + ", note " + cNote
