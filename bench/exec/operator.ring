# RING'S OPERATOR OVERLOADING, measured on 1.27 (F-69). An object on the
# LEFT of any operator calls its class's `operator(cOp, x)` with the
# operator's own text -- `[]` and a statement included -- and the call's
# value is the expression's value; `-o` is operator("neg", 0). An object on
# the RIGHT of an arithmetic, bitwise or ordering operator is called with
# "r" in front, except that a LIST on the left of `+` appends the object
# and `=` / `!=` compare plainly. A class with no `operator` raises R50,
# except for `=` / `!=`, which compare plainly. Assignment copies the
# result as it copies any object, and a list `+` gives the variable its
# own copy of the list. Softanza's stzList, stzHashList, stzString and
# stzDuration are written against all of this.

o = new V(10)
? "1 o + 5:      " + Show(o + 5)
? "2 o - 3:      " + Show(o - 3)
? "3 o * 2:      " + Show(o * 2)
? "4 o / 2:      " + Show(o / 2)
? "5 o[3]:       " + Show(o[3])
? "6 o[:key]:    " + Show(o[:key])
? "7 o = 10:     " + Show(o = 10)
? "8 o < 20:     " + Show(o < 20)
? "9 o + o:      " + Show(o + o)
? "10 o & 1:     " + Show(o & 1)
? "11 o % 3:     " + Show(o % 3)
? "12 o ^ 2:     " + Show(o ^ 2)
? "13 o != 10:   " + Show(o != 10)
? "14 o + 'ab':  " + Show(o + "ab")
? "15 o + [1,2]: " + Show(o + [1, 2])
? "16 -o:        " + Show(-o)
o + 100
? "17 after `o + 100` as a statement: log " + len(o.log) + " last " + o.log[len(o.log)]
? "18 5 + o:     " + Show(5 + o)
? "19 5 < o:     " + Show(5 < o)
? "20 5 = o:     " + Show(5 = o)
? "21 5 != o:    " + Show(5 != o)
? "22 'a' + o:   " + Show("a" + o)
? "23 [1] + o:   " + Show([1] + o)
? "24 5 - o:     " + Show(5 - o)
? "25 5 * o:     " + Show(5 * o)
? "26 5 >= o:    " + Show(5 >= o)
if 5 < o ? "27 `if 5 < o` took the branch" else ? "27 not taken" ok
p = new W
try
	? "28 no operator, p + 1: " + Show(p + 1)
catch
	? "28 no operator, p + 1: " + cCatchError
done
try
	? "29 no operator, p[1]: " + Show(p[1])
catch
	? "29 no operator, p[1]: " + cCatchError
done
? "30 no operator, p = 1: " + Show(p = 1)
if p = 1 ? "31 p = 1 truthy" else ? "31 no operator: p = 1 is plain, falsy" ok
if p != 1 ? "32 p != 1 truthy" else ? "32 falsy" ok
try
	if p < 1 ? "33 p < 1 truthy" else ? "33 falsy" ok
catch
	? "33 " + cCatchError
done
q = new X
? "34 returns This: " + Show(q + 1)
? "35 chain: " + Show((q + 1) + 2)
r = q + 1
r.n = 100
? "36 q.n after r = q + 1 and r.n = 100 (assignment copies): " + q.n
if q < 3 ? "37 `if q < 3` truthy (operator returned This)" else ? "37 falsy" ok
z = new Z
? "38 operator returning a number: " + (z * 3) + " and " + (z < 3)
if z < 3 ? "39 truthy" else ? "39 falsy (operator returned 0)" ok
aL = [1]
x = aL + 2
add(x, 3)
? "40 aL " + len(aL) + " x " + len(x)

func Show(v)
	if isObject(v) return "OBJECT(" + classname(v) + ") n=" + v.n ok
	if isList(v) return "LIST len " + len(v) ok
	if isNumber(v) return "NUMBER " + v ok
	return "STRING '" + v + "'"

class V
	n = 0
	log = []
	def init(pn)
		n = pn
	def operator(cOp, x)
		log + cOp
		if isObject(x) return "op " + cOp + " with an object" ok
		if isList(x) return "op " + cOp + " with a list" ok
		return "op " + cOp + " with " + x

class W
	n = 1

class X
	n = 0
	def operator(cOp, x)
		n = n + x
		return This

class Z
	n = 0
	def operator(cOp, v)
		if cOp = "*" return 42 ok
		return 0
