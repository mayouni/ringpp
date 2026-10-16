# eval(aCodes[i]): THE STRING IS AN ELEMENT OF A LIST THE FUNCTION FILLED.
#
# stzTable.InsertCalculatedRow builds `'_value_ = ' + formula` into a
# variable, appends it to a list, evals each element and reads _value_.
# The literal-prefix rule (F-72) declared a name spelled in the eval's own
# argument, or in an assignment to the variable passed; an element of a list
# was one step further, so the read of _value_ was refused under Rule A.
# Every write INTO the list is followed now -- `L + v`, add, insert,
# `L[k] = v`, a list literal -- and each value read as an eval argument is.
# Every row taken from Ring 1.27 first. 2026-09-27.

func main
	? "01 appended: " + @@list(f1())
	? "02 add(): " + f2()
	? "03 L[k] = v: " + f3()
	? "04 a list literal: " + f4()
	? "05 insert(): " + f5()

func f1
	aCodes = []
	for i = 1 to 3
		cCode = "" + (i * 10)
		cCode = 'v = ' + cCode
		aCodes + cCode
	next
	aOut = []
	for i = 1 to 3
		eval(aCodes[i])
		aOut + v
	next
	return aOut

func f2
	aCodes = []
	add(aCodes, 'w = 5')
	eval(aCodes[1])
	return w

func f3
	aCodes = ["", ""]
	aCodes[2] = 'x = "set by index"'
	eval(aCodes[2])
	return x

func f4
	aCodes = [ 'y = 7', 'y = 8' ]
	eval(aCodes[2])
	return y

func f5
	aCodes = []
	insert(aCodes, 0, 'z = "inserted"')
	eval(aCodes[1])
	return z

func @@list aL
	s = "["
	for i = 1 to len(aL)
		if i > 1 s += "," ok
		s += "" + aL[i]
	next
	return s + "]"
