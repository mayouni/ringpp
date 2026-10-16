# EVAL RUNS IN ITS CALLER'S SCOPE (F-72, C-9 revised), measured on 1.27:
# the caller's locals, parameters and attributes are written; a NEW name
# becomes the caller's variable and the caller's own compiled code reads
# it afterwards; the value is "" unless the code returns; an error inside
# is caught by the caller's try; statements, an if, an append and a nested
# eval all work. Ring++ compiles the string at run time in the calling
# frame -- the name an eval string spells in its literal prefix is declared
# for the caller ahead of time, which is what row 6's `fresh` needs.
# A function or class DEFINED inside eval is real on Ring and not in this
# first version (no estate site does it); named, not in these rows.

x = 1
eval("x = x + 41")
? "1 top-level local written: " + x
eval("y = 7")
? "2 a NEW top-level name: " + y
? "3 the value of eval: [" + eval("z = 5") + "] type " + type(eval("z = 5"))
r = eval("return 6")
? "4 eval with a return: [" + r + "]"
? "5 " + F()
? "6 " + G(10)
o = new K
? "7 " + o.M()
? "8 " + o.n
try
	eval("bad = 1 / 0")
catch
	? "9 caught under the caller's try: " + cCatchError
done
try
	eval("nosuchfunc()")
catch
	? "10 " + cCatchError
done
eval("p = 1" + nl + "p = p + 1" + nl + "? '11 two statements: ' + p")
eval("if x > 40  ? '12 an if inside eval' ok")
aL = [1, 2]
eval("aL + 3")
? "13 list appended: " + len(aL)
eval("? '14 eval of eval: ' + eval('1 + 1')")
? "15 " + H()
? "16 a call by name inside eval: " + J()
? "17 " + Q()

func F
	a = 5
	eval("a = a * 2")
	return "a function's local written: " + a

func G(p)
	eval("p = p + 1")
	eval("fresh = p * 2")
	return "a parameter written: " + p + ", a new local read: " + fresh

func H
	eval("v = 3")
	try
		return "18 " + v
	catch
		return "18 " + cCatchError
	done

func J
	eval("t = Twice(21)")
	return t

func Twice(n)
	return n * 2

func Q
	eval("k = new K")
	eval("k.n = 55")
	return "an object built inside eval: " + k.n

class K
	n = 1
	@aAnswers = []
	aSeen = [[1], [2]]
	def M
		eval("n = n + 10")
		eval("This.n = This.n + 100")
		eval("t = extra()")
		# an APPEND to an attribute inside eval -- stzNatural's
		# `@aAnswers + @result` -- through @, bare, and a subscript
		eval("@aAnswers + 5")
		eval("@aAnswers + 6 + 7")
		eval("aSeen + [3]")
		eval("aSeen[1] + 9")
		return "attributes through eval: " + n + " method: " + t +
			" answers: " + len(@aAnswers) + " seen: " + len(aSeen) + "/" + len(aSeen[1])
	def extra
		return 0
