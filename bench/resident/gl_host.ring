# RUNG 7 OF THE RESIDENT VM: a class REPLACED with attributes added while
# its objects exist -- each object made before takes the new attributes,
# starting as declared, at the first access that needs them; a list of its
# own. Run with `rnxc resident gl_host.ring`; Ring has no replacement --
# golden.
? "host: start"
Q = char(34)
? "admit: " + admitfile("gl_lib.ring")
oT = MakeTally()
oT.Add(5)
oT.Add(7)
aKeep = [MakeTally(), MakeTally()]
aKeep[1].Add(3)
# one object for each way of reaching a gained attribute FIRST
oP = MakeTally()
oA = MakeTally()
oG = MakeTally()
oRd = MakeTally()
oS = MakeTally()
oW = MakeTally()
oRd.Add(2)
aFind = [MakeTally(), MakeTally()]
? "before: " + oT.Total()

? "replace: " + replacefile("gl_tally2.ring")
? "the total kept: " + oT.Total()
# each reaches a gained attribute first, by its own path
? "printed first:"
? oP
? "listed first: " + len(attributes(oA))
? "getattribute first: " + len(getattribute(oG, "atags"))
? "a method reading it first: " + oRd.Summary()
oS.SetNote("set")
? "a method writing it first: " + oS.Summary()
oW.Tag("w")
? "a method appending to it first: " + oW.Summary()
? "found first: " + find(aFind, 0, 1, "nadds")
? "a gained attribute, by name: " + oT.nAdds
oT.Add(1)
oT.Tag("red")
? "after an add: " + oT.Summary()
? "printed:"
? oT
? "attributes: " + len(attributes(oT))
? "getattribute: " + getattribute(oT, "nadds")
setattribute(aKeep[2], "nadds", 40)
? "setattribute on one held only in a list: " + aKeep[2].nAdds
aKeep[1].Tag("blue")
aKeep[1].Tag("green")
? "a list of its own: " + len(aKeep[1].aTags) + " and " + len(oT.aTags)
? "found by the gained attribute: " + find(aKeep, 40, 1, "nadds")
oCopy = oT
oCopy.Add(100)
? "a copy: " + oCopy.Summary() + " / the original: " + oT.Summary()
oNew = MakeTally()
? "made after, by the old new site: " + oNew.Summary()

# a second growth: an object from before both takes both
? "replace again: " + replacecode("tally3", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = [1, " + Q + "x" + Q + ", [true]]" + nl)
? "both: " + aKeep[2].nLimit + " " + len(aKeep[2].aPair) + " " + aKeep[2].aPair[3][1] + " " + aKeep[2].nAdds

# refused, the program unchanged after each
aRefuse = [
	["swap", "class Tally" + nl + tab + "nAdds = 0" + nl + tab + "nTotal = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "nX = 0" + nl],
	["drop", "class Tally" + nl + tab + "nTotal = 0" + nl],
	["computed", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "nLen = len(" + Q + "ab" + Q + ")" + nl],
	["region", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "nTwice = 0" + nl + tab + "nTwice++" + nl],
	["loop", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "for i = 1 to 2" + nl + tab + tab + "nLoop = i" + nl + tab + "next" + nl],
	["twice", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "nTwo = 1" + nl + tab + "nTwo = 2" + nl]
]
for aR in aRefuse
	try
		replacecode(aR[1], aR[2])
		? aR[1] + ": admitted"
	catch
		? aR[1] + ": " + cCatchError
	done
next
? "after the refusals: " + oT.Summary()

# a class the program holds that inherits from it: refused
? "admit a subclass: " + admitcode("sub", "func MakeSub return new SubTally" + nl + "class SubTally from Tally" + nl + tab + "cKind = " + Q + "sub" + Q + nl)
try
	replacecode("tally4", "class Tally" + nl + tab + "nTotal = 0" + nl + tab + "nAdds = 0" + nl + tab + "aTags = []" + nl + tab + "cNote" + nl + tab + "nLimit = -2.5" + nl + tab + "aPair = []" + nl + tab + "nMore = 1" + nl)
catch
	? "with a subclass: " + cCatchError
done
? "host: end"
