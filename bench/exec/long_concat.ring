# A long `+` chain in a return: the grammar cuts it at a `+` even alone in
# a function, and re-parsing the same text reproduces the cut. The payload
# is parenthesised on the second try. Before that, G() returned "3 " and
# evaluated the rest as a discarded statement -- a wrong answer, silently.
? "A " + G()
? "B " + H()
func G()
	a = [3, "3 items", [1,2,3]]
	return "" + len(a) + " " + a[1] + " " + a[2] + " " + len(a[3]) + " " + a[3][2]
func H()
	a = [3, "3 items", [1,2,3]]
	r = "" + len(a)
	r = r + " " + a[1]
	r = r + " " + a[2]
	r = r + " " + len(a[3])
	r = r + " " + a[3][2]
	return r
