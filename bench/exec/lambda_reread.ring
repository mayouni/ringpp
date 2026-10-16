wwwwwwwwwwwwwwwww = func z { return "WRONG -- another lambda ran" }
# A LAMBDA INSIDE A STATEMENT THE COMPILER RE-READS -- 2026-10-05.
#
# A `#` comment inside an expression, or a line ending in `.`, makes the
# compiler read the statement again from a copy (F-80, F-71), parsed behind
# a `func __reread()` header -- so every byte offset in the copy is off by
# that header. A lambda in such a statement was looked up by its offset
# ALONE: it matched nothing and the statement was refused ("lambda was not
# lowered", 49 rows of the wide suite: the reactive streams, the graph
# planner), or it matched another lambda standing at that offset somewhere
# in the unit and RAN IT. Line 1 is such a lambda: byte 20, exactly where
# row 4's falls in its re-read copy. On the build before the fix, row 4 run
# alone called line 1's lambda, got its string, and `x[:x]` raised "Bad
# parameter type!"; rows 1-3, 5 and 6 were refused.
#
# Every row is the oracle's answer, and official Ring 1.27's.

# 1  a comment after a comma, in the list a lambda returns
fList = func t {
	return [
		:a = 1,
		:b = 2 + 10,  # a comment
		:c = 3
	]
}
x = call fList(1)
? "1 " + x[:b] + " " + x[:c]

# 2  a comment after the last item
fLast = func t {
	return [
		:a = 1,
		:b = 2     # the last
	]
}
x = call fLast(1)
? "2 " + x[:b]

# 3  a comment among a call's arguments
fArgs = func t {
	return Sum3(1,  # one
	            2,
	            3)
}
? "3 " + call fArgs(1)

# 4  the offset that matched line 1's lambda
f = func t {
	return [ :x = "RIGHT",   # a comment
	         :y = 2 ]
}
x = call f(1)
? "4 " + x[:x]

# 5  a lambda inside a lambda, both read again
fOuter = func a {
	fInner = func b {
		return [ :v = b,   # inner
		         :w = 2 ]
	}
	y = call fInner(a)
	return y[:v] + y[:w]
}
? "5 " + call fOuter(40)

# 6  a chain continued past a `.` at the end of a line, lambdas as arguments
oP = new Pipe
oP.Add(func n { return n * 2 }).
   Add(func n { return n + 1 })
? "6 " + oP.Run(5)

func Sum3 a, b, c
	return a + b + c

class Pipe
	@aF = []

	func Add f
		@aF + f
		return This

	func Run n
		for i = 1 to len(@aF)
			g = @aF[i]
			n = call g(n)
		next
		return n
