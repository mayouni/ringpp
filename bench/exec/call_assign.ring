# `F() = v` AS A STATEMENT: the call runs, then the right side, then R34.
#
# Every row taken from Ring 1.27 first, both builds (2026-09-27). A number,
# string or NULL result is `Error (R34) : Variable is required for the
# assignment operation`, catchable, AFTER both sides have run; a list result
# is taken silently. Ring++ refused the statement, so neither side ran.
# max/string/stzSringConstraints.ring:55 is the estate's one such line.
#
# LEFT OUT ON PURPOSE: for a list or an object Ring WRITES THROUGH the
# result -- `o.Me() = 5`, with Me returning This, replaces o itself, and
# the next `o.x` is R13. Ring++ does nothing there; no estate site does it.

$n = 0
try F() = 0 catch ? "01 top level: " + cCatchError done
try f1() catch ? "02 in a function: " + cCatchError done
try F() = G() catch ? "03 both sides run first: " + cCatchError done
o = new K
try o.Run() catch ? "04 This.M(1) = 0 in a method: " + cCatchError done
try f2() catch ? "05 a list result: " + cCatchError done
try f3() catch ? "06 a string result: " + cCatchError done
try N() = 1 catch ? "07 a NULL result: " + cCatchError done
? "08 ran on, calls counted: " + $n

func F
	$n++
	? "   F ran"
	return 5
func G
	? "   G ran"
	return 9
func L
	$n++
	? "   L ran"
	return [1, 2]
func S
	$n++
	? "   S ran"
	return "abc"
func N
	$n++
	? "   N ran"

func f1
	F() = 7
	? "   after F() = 7"
func f2
	L() = 7
	? "   after L() = 7"
func f3
	S() = "x"
	? "   after S() = x"

class K
	def Run
		This.M(1) = 0
		? "   after This.M(1) = 0"
	def M x
		$n++
		? "   M ran with " + x
		return 1
