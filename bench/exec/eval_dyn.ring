# F-107. A name an eval assigns that the program never declares is a
# variable of the FRAME the eval runs in -- later evals and the function's
# own code read it -- and at the top level a GLOBAL every function reads.
# A callee does not see its caller's, and every call starts fresh: a read
# before any assignment is R24, naming it. Softanza's StzForEachObjectQ().Exec builds
# such names from a list (`@acVars[j] + ' = ...'`), which is how
# base/test/global/21_pr met it; Ring++ refused the name, or kept it in a
# register of the eval's own that died with it. Uncaught at the end.
cG = "gtop"
eval(cG + " = 11")
? gtop
ReadsGlobal()
Frame(1)
Frame(2)
o = new K
o.M()
Lists()
Last()

func ReadsGlobal
	? "a function reads it: " + gtop

func Frame n
	if n = 2
		try
			eval("? zz")
		catch
			? "a fresh call: " + cCatchError
		done
	else
		cN = "z" + "z"
		eval(cN + " = 1")
		eval("zz += 4")
		eval("? zz")
		? "its own code reads it: " + zz
		try
			Callee()
		catch
			? "a callee: " + cCatchError
		done
	ok

func Callee
	eval("? zz")

func Lists
	cN = "al"
	eval(cN + " = [1]")
	eval("al + 2")
	eval("add(al, 3)")
	eval("? len(al)")

func Last
	eval("? never_made")

class K
	attr = 1
	def M
		cN = "mv"
		eval(cN + " = attr + 41")
		eval("? mv")
