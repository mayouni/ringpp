# A BARE CALL INSIDE `obj { ... }`, measured on 1.27: the object's method
# when its class has one, otherwise the global FUNCTION of that name --
# and the receiver's class is not always known at compile time. Softanza's
# tests write `StzLocaleQ([...]) { Then("...", NativeNthDayOfWeek(1), "x") }`,
# where Then is the harness's function and stzLocale has no such method;
# Ring++ raised R14 "then" until 2026-09-24.

o = Make("K")
o {
	? "1 " + Tag("brace")
	? "2 " + Own(5)
}
p = Make("L")
p {
	? "3 " + Tag("brace")
}
q = Make("K")
q { ? "4 " + Tag(Own(1)) }

func Make(c)
	if c = "K" return new K ok
	return new L

func Tag(s)
	return "function Tag: " + s

func Own(n)
	return "function Own: " + n

class K
	def Own(n)
		return "method Own: " + n

class L
	def Tag(s)
		return "method Tag: " + s
