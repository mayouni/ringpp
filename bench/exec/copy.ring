# Ring's value model, measured 2026-09-10 on both builds: a list or an
# object is COPIED at every transfer -- into a variable, an attribute, an
# element, a list literal, `add()`, and a method's `return` -- deeply
# (nested lists and nested objects included), and passed by REFERENCE to a
# parameter and as `this`. Before C-7 rnx aliased objects on assignment
# and, worse, CLONED a list a callee wrote through its parameter, so
# `f(a)` with `l[1] = 99` inside left the caller's a untouched.
a = [1, 2]
f(a)
? "A list param mutated in callee: " + a[1]
? "A2 add() on a list param: len=" + addOne(a)
o = new K
g(o)
? "B object param mutated in callee: " + o.@x
o.Set(7)
? "C method writes this: " + o.@x
p = o
p.Set(9)
? "D copy then method: o=" + o.@x + " p=" + p.@x
b = a
b[1] = 5
? "E list copy on assignment: a[1]=" + a[1] + " b[1]=" + b[1]
h = new K
h.@o2 = new K
q = h
q.@o2.@x = 3
? "F nested object copy: h.@o2.@x=" + h.@o2.@x + " q.@o2.@x=" + q.@o2.@x
n = [[1, 2], [3, 4]]
e = n[1]
e[1] = 77
? "G x = a[i] copies: n[1][1]=" + n[1][1]
m = h.@l
m[1] = 88
? "H x = o.attr copies: h.@l[1]=" + h.@l[1]
y = [9]
big = [1]
big[1] = y
y[1] = 10
? "I a[i] = y copies: big[1][1]=" + big[1][1]
? "J add(w, y) copies: " + addThen(y)
lit = [y]
y[1] = 12
? "K [y] literal copies: lit[1][1]=" + lit[1][1]
r = o.GetL()
r[1] = 66
? "L x = method() copies: o.@l[1]=" + o.@l[1]
func f(l)
	l[1] = 99
func addOne(l)
	add(l, 3)
	return len(l)
func g(ob)
	ob.@x = 5
func addThen(v)
	w = [1]
	add(w, v)
	v[1] = 11
	return "w[2][1]=" + w[2][1]
class K
	@x = 0
	@l = [1, 2]
	@o2 = NULL
	def Set(v)
		@x = v
	def GetL()
		return @l
