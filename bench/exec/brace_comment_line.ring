# F-104. A `#` comment inside a brace makes the compiler read the whole
# brace statement again from a copy, and every instruction of that copy
# reported the statement's FIRST line: the call to M below was `Called from
# line 7` -- the brace -- where Ring says 8. Softanza's base/test/list/
# 546_removew has this shape, `RemoveW(...)` followed by a `#-->` line.
o = new K
o {
	M(5)

	? C()
	#--> 1
}

class K
	def M n
		? lower(n)
	def C
		return 1
