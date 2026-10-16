$g = 10
x = 5
? "T1 " + x
x = x + 1
? "T2 " + x
a = [1, 2]
a + 3
a[1] = 9
? "T3 " + len(a) + " " + a[1]
o = new TK
? "T4 " + o.M()
for i = 1 to 2
	s = i
next
? "T5 " + s
? "T6 " + F()
func F()
	return $g + 1
class TK
	def M()
		return 42
