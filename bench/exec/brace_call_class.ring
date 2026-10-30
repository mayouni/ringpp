# Inside a brace a bare call is the object's method first, so a global
# function of the same name says nothing about what the call answers.
o = new K
o { ? "1 " + len(Check()) }
o { ? "2 " + Check()[1] }
o { x = Check()  ? "3 " + len(x) }
o { ? "4 " + len(N()) }
o {
	for i = 1 to 2000
		y = N()
		z = len(N()) + y[2]
	next
	? "5 " + len(y) + " " + z
}
KQ() { ? "6 " + len(Check()) + " " + N()[3] }
? "7 " + len(Check()) + " " + N()
F()

func F
	o2 = new K
	o2 {
		w = N()
		? "8 " + len(w) + " " + w[1]
	}

func Check return "a string"
func N return 5
func KQ return new K

class K
	def Check return [10, 20, 30]
	def N return [1, 2, 3]
