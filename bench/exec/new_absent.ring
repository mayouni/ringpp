# `new K` OF A CLASS NOBODY DEFINES IS R11 WHERE THE LINE RUNS.
#
# Every row taken from Ring 1.27 first, both builds agreeing (2026-09-27):
# catchable, the class name folded to lower case, and raised BEFORE the
# constructor's arguments are evaluated -- row 04 prints no argument line.
# Ring++ refused the statement instead ("commitment #4 earning its keep",
# since most such sites are typos). But at the top level a refused
# statement stopped the program inside its own `try`, where Ring catches,
# and a refusal is the safe answer only when the alternative is a WRONG
# one (F-63); here the alternative is Ring's own. The typo-catching lives
# on in `rnxc check` (rpp/unknown-class, F-48), and the census counts
# these sites apart and lists each under --all.

try o = new NoSuchClass catch ? "01 top new K: " + cCatchError done
try o = new NoSuchClass(1) catch ? "02 top new K(1): " + cCatchError done

func main
	try f1() catch ? "03 fn new K: " + cCatchError done
	try f2() catch ? "04 fn new K(args), are the args evaluated: " + cCatchError done
	try ? "05 untaken branch: " + f3(0) catch ? "05: " + cCatchError done
	try ? "06 taken branch: " + f3(1) catch ? "06: " + cCatchError done
	try f4() catch ? "07 new K { }: " + cCatchError done
	try ? "08 as a value: " + f5() catch ? "08: " + cCatchError done
	try f6() catch ? "09 mixed case: " + cCatchError done
	try f7() catch ? "10 new K() as a statement: " + cCatchError done
	? "11 ran on"

func f1
	o = new NoSuchClass
func f2
	o = new NoSuchClass(Say("arg evaluated"))
func f3 n
	if n = 1
		o = new NoSuchClass
	ok
	return "fine"
func f4
	o = new NoSuchClass { x = 1 }
func f5
	return classname(new NoSuchClass)
func f6
	o = new stzNOSUCHCLASS
func f7
	new NoSuchClass()

func Say x
	? "   (" + x + ")"
	return x
