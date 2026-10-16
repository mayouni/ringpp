# Appending a LIST or an OBJECT to a list appends a COPY on Ring: the
# appended value does not change when the original is changed after.
# Softanza's CombinationsXT builds every tuple in one working list,
# `_aResult_ + _aCurrent_` then `del(_aCurrent_, len(_aCurrent_))`, and its
# History() keeps each step's content the same way.

a = []  b = [1, 2]
a + b
del(b, 1)
? "1 a + b, then b changes      : " + len(a[1]) + " " + len(b)
a = []  b = [1, 2]
add(a, b)
b[1] = 99
? "2 add(a, b), then b changes  : " + a[1][1] + " " + b[1]
a = []  o = new K
a + o
o.v = 7
? "3 a + o, then o changes      : " + a[1].v + " " + o.v
a = []  b = [1, 2]
c = a + b
add(b, 3)
? "4 c = a + b, then b changes  : " + len(a[1]) + " " + len(c[1]) + " " + len(b)
a = []  b = [[1], [2]]
a + b
b[1][1] = 50
? "5 nested, then b changes     : " + a[1][1][1] + " " + b[1][1]
? "6 recursion like CombinationsXT : " + Show(Pairs([1, 2]))
a = []  b = [1]
insert(a, 0, b)
b[1] = 2
? "7 insert(a, 0, b), then b    : " + a[1][1]
? "done"

func Pairs(aL)
	aR = []  aC = []
	Gen(aL, aC, aR)
	return aR

func Gen(aL, aC, aR)
	if len(aC) = 2
		aR + aC
		return
	ok
	for i = 1 to len(aL)
		aC + aL[i]
		Gen(aL, aC, aR)
		del(aC, len(aC))
	next

func Show(v)
	if isList(v)
		s = "["
		for i = 1 to len(v)
			if i > 1  s += ","  ok
			s += Show(v[i])
		next
		return s + "]"
	ok
	return "" + v

class K
	v = 1
