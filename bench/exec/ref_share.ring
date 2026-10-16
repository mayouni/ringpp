# F-118. Ring 1.21's references: once a list or an object has been through
# `ref()`, every later copy of it SHARES it -- an assignment from a
# variable, a list item or a call's result, a list literal's item, `+` --
# for as long as it has a second named holder; with one left, an
# assignment copies again. Ring's own test is ring_list_isref_gc at each of
# its copy sites (vmstack.c:252, vmlists.c:103/120/404/530, vmexpr.c:1226).
# Ring++ shared only at the `ref()` site itself and copied at every later
# assignment, so a referenced object read back into a local and mutated
# lost the mutation, silently.
#
# Found through Softanza: stkMemory keeps its buffers as `ref(_oBuffer_)`
# in a registry and does `_oBuffer_ = @aBuffers[id]` then
# `_oBuffer_.ReleaseWritePointer()` -- row 1 is that shape: on Ring the
# buffer is released, on the build before it stayed held. Measured on both
# 1.27 builds, every row the same on both. refcount() counts the NAMED
# holders, as Ring does (rows 9-10), and that count decides row 8.

m = new Mem
m.Create("b1")
m.Release("b1")
? "1 a released through a local: " + m.Has("b1")
o = new Buf
aL = [["k", ref(o)]]
x = aL[1][2]
x.n = 5
? "2 x = aL[1][2], x.n = 5 -> o.n " + o.n
y = o
y.n = 6
? "3 y = o, y.n = 6 -> o.n " + o.n
p = new Buf
z = p
z.n = 7
? "4 never referenced: z = p, z.n = 7 -> p.n " + p.n
g = new Holder(p)
w = g.Fetch()
w.n = 8
? "5 w = g.Fetch() -> p.n " + p.n
a = [1, 2, 3]
b = ref(a)
c = a
add(a, 4)
? "6 c = a after ref(a): len(c) " + len(c) + ", len(b) " + len(b)
d = [1, 2]
e = d
add(d, 3)
? "7 plain e = d: len(e) " + len(e)
q = [1, 2]
r = ref(q)
r = NULL
s = q
add(q, 3)
? "8 the second holder gone, s = q copies: len(s) " + len(s)
k = 1:10
k2 = ref(k)
? "9 refcount(k) " + refcount(k)
? "10 refcount(k2) " + refcount(k2)

class Mem
	aB = []
	func Create id
		ob = new Buf
		ob.lHeld = 1
		aB + [id, ref(ob)]
	func Release id
		ob = aB[id]
		ob.lHeld = 0
	func Has id
		return aB[id].lHeld

class Buf
	n = 0
	lHeld = 0

class Holder
	oP
	func init h
		oP = ref(h)
	func Fetch
		return oP
