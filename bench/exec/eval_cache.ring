# THE SAME eval STRING, AGAIN AND AGAIN -- what Ring++'s eval cache must
# not change. Ring re-parses every time; Ring++ compiles a (caller, string)
# pair once and keeps the code resident. Each row is a way that could go
# wrong: the same text in two frames whose locals sit in different
# registers, the same text at the top level and in a method, a cached
# string that raises on every call, one whose value changes with the
# caller's state, and a nested eval inside a cached one.

x = 100
for i = 1 to 3
	eval("x = x + 1")
next
? "1 top level, three times: " + x
? "2 " + A(5) + " " + B(7)
? "3 again: " + A(5) + " " + B(7)
nCaught = 0
for i = 1 to 4
	try
		eval("nope = 1 / 0")
	catch
		nCaught++
	done
next
? "4 a cached string that raises, caught each time: " + nCaught
aL = []
for i = 1 to 3
	eval("aL + i * 10")
next
? "5 appends through a cached string: " + len(aL) + " last " + aL[3]
? "6 " + C()
o = new K
? "7 " + o.M() + " " + o.M()
s = ""
for i = 1 to 3
	s += "" + eval("return i * i") + ","
next
? "8 a cached return that reads the loop: " + s
n = 0
for i = 1 to 3
	eval("n = n + eval('return 2')")
next
? "9 nested eval inside a cached one: " + n

func A p
	q = 1
	for k = 1 to 3
		eval("q = q + p")
	next
	return "A=" + q

func B p
	w = 0
	z = 1000
	for k = 1 to 3
		eval("q = z + p")
	next
	return "B=" + q

func C
	t = 0
	for k = 1 to 5
		eval("t = t + k")
	next
	return "a loop variable read by a cached string: " + t

class K
	n = 0
	def M
		eval("x = n + 1")
		eval("n = x")
		return n
