# F-91, measured on both 1.27 builds. `x = new K(args)` stores the new
# object into x BEFORE the arguments are evaluated: `o = new K([1] + o)`
# appends the object itself, `q = new K(q)` hands init the object. A plain
# self-read is still R24 (row 1). And a PARAMETER spelt with `$` is the
# parameter (row 4): Softanza's StzListOfSectionsQ().pvtMax(n1, $n2).
# Ring++ raised R24 on rows 2, 3, 5 and read the global on row 4.

? "1 top, string        : " + R1()
? "2 new, arg reads o   : " + R2()
? "3 new, top level     :"
o = new K2([1] + o)
? "  type of o          : " + type(o) + " " + classname(o)
? "  len(o.a)           : " + len(o.a)
? "  type(o.a[2])       : " + type(o.a[2])
? "4 $param             : " + P(3, 7) + " " + P(9, 2)
? "5 new in a function  : " + R5()
? "6 $param written     : " + W(4, 5)
? "done"

func R1
	try
		y = "a" + y + "z"
		return y
	catch
		return cCatchError
	done

func R2
	try
		p = new K2([1] + p)
		return "len " + len(p.a) + ", second is " + type(p.a[2])
	catch
		return cCatchError
	done

func R5
	try
		q = new K2(q)
		return type(q.a) + " " + classname(q.a)
	catch
		return cCatchError
	done

func P(n1, $n2)
	if n1 > $n2
		return n1
	ok
	return $n2

func W(n1, $n2)
	$n2 = $n2 * 10
	return n1 + $n2

class K2
	a
	def init(x)
		a = x
