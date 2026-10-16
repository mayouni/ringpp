# F-105. len() and `for x in` on an OBJECT ask the object: Ring calls the
# class's operator("len", 0) for len(o) and before every turn of the loop,
# then operator("[]", i) for each item, and writes nothing back into it
# (genlib_e.c:1098, vmstack.c:794). Over what is no container a for-in is
# R29, catchable, reported at the `for` line -- Ring++ said "Bad parameter
# type!" a line late, the bound being tested after the body. ref() and
# reference() take a list or an object only; refcount() of anything else
# is 1 (list_e.c:737, :757). Uncaught at the end, so the line prints.
o = new K
? len(o)
for x in o
	? "x = " + x
next
for x in o
	x = 99
next
? o.aL
try
	for x in 5
		? x
	next
catch
	? "caught: " + cCatchError
done
try
	? len(5)
catch
	? "caught: " + cCatchError
done
try
	? ref("abc")
catch
	? "caught: " + cCatchError
done
? len(ref([1, 2]))
? refcount(5)
? refcount("a")
f()

func f
	n = 5
	for x in n
		? x
	next

class K
	aL = [10, 20, 30]
	def operator cOp, x
		? "op " + cOp + " [" + x + "] " + type(x)
		if cOp = "len" return len(aL) ok
		if cOp = "[]" return aL[x] ok
		return 0
