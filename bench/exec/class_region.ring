# F-121. A class region runs WHOLE at every `new`, in order, before init:
# a `?`, a call, a loop, an `if`, AddAttribute(self, ...). Ring++ ran only
# its assignments and bare declarations and dropped the rest without a word,
# so `total` below stayed 0 and `z` did not exist. Every name the region
# assigns is an attribute of the object -- a loop's variable too, holding
# the value that ended the loop -- and attributes() lists them in that
# order. A parent's region runs before the child's. Measured on both 1.27
# builds 2026-10-14, every row the same on both. Softanza's one such line is
# `vr(:say)` in stzExtinPerl's class say.

? "1 before new"
o = new K
? "4 after new: x=" + o.x + " y=" + o.y + " total=" + o.total + " i=" + o.i
? "5 attributes:" + J(attributes(o))
o2 = new K
? "6 second object: total=" + o2.total + " z=" + o2.z
p = new P(5)
? "9 P: v=" + p.v + " w=" + p.w
c = new Child
? "12 child: a=" + c.a + " b=" + c.b + " n=" + c.n
? "13 child attributes:" + J(attributes(c))
q = new Q
? "15 Q: " + q.Show() + ", attributes:" + J(attributes(q))

func J aL
	r = ""
	for e in aL r += " " + e next
	return r

func Seven
	return 7

class K
	? "2 region runs at new"
	x = 1
	y = Seven()
	total = 0
	for i = 1 to 3
		total += i
	next
	if x = 1 z = "one" else z = "other" ok
	AddAttribute(self, "added")
	added = 99
	? "3 region end, added=" + added

class P
	v = 1
	? "7 P region before init, v=" + v
	w = v * 10
	func init n
		? "8 init sees w=" + w
		v = n

class Base
	a = 1
	? "10 base region, a=" + a
	n = 0
	while n < 3 n++ end

class Child from Base
	b = a + 1
	? "11 child region, a=" + a + " b=" + b + " n=" + n

class Q
	this.name = "app"
	self.version = "1.0"
	? "14 Q region reads name=" + name + " version=" + version
	func Show
		return name + " " + version
