# Inside a brace a bare name is a local, then the object's attribute, then a
# global; a name none of them has becomes a variable of the enclosing scope --
# a global at the top level, a local in a function (C-6 revised).
KQ() { aR = Make()  ? "1 " + len(aR) }
? "2 " + len(aR)
KQ() { aR + 4 }
? "3 " + len(aR)
KQ() { Tag = "set" }
o = KQ()
o { Tag = "on o" }
? "4 " + o.Tag
KQ() { n2 = 7  n2 += 1 }
? "5 " + n2
F()

func F
	KQ() {
		w = Make()
		w + 9
		? "6 " + len(w) + " " + w[4]
	}
	o3 = new K
	o3 { v = 3  Tag = "f" }
	? "7 " + v + " " + o3.Tag

func KQ return new K
func Make return [1, 2, 3]

class K
	Tag = "tag"
	def Days return 5
