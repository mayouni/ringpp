# RUNG 7, the oracle's half: an object made under the REPLACED Tally from
# the start, given the total the migrated one kept -- every line it prints
# must be the line the migrated object printed (bench/resident.py)
load "gl_tally2.ring"
oT = new Tally
oT.nTotal = 12
oT.Add(1)
oT.Tag("red")
? "after an add: " + oT.Summary()
? "printed:"
? oT
? "attributes: " + len(attributes(oT))
? "getattribute: " + getattribute(oT, "nadds")
