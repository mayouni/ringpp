# A CALL'S RESULT IS A PLACE, and so is another object's attribute.
#
# `q.L()[1] = 99`, `add(q.L(), 99)`, `del(This.HashList(), n)` and
# `o.aL[1] = 99` all write through to the ORIGINAL on Ring. Ring++ refused
# every one of them: the root of a mutable path had to be a bare name.
#
# THE REASON IT HAD TO BE WAS GONE. The compiler borrows a global and an
# attribute for writing rather than reading them into a temporary, because
# a read took the container's count to 2 and the write then CLONED it.
# That was copy-on-write, and C-7 removed it on 2026-09-11 when the copy
# moved to the assignment; `cowFor` has been the identity function ever
# since. A temporary holding a list IS the list, so any expression is a
# place -- and the notes saying otherwise sat in four builtins and in the
# indexed assignment, reading like facts.
#
# That is the third correction whose old rule outlived it in the code:
# `s[i]` was a byte to the type table nine days after C-3 made it a
# string, a widened parameter was raised after the fixpoint that carries
# it, and now this. A correction has to carry the code that encoded the
# old rule with it.
#
# The ONE row here that is not about writing through: a fresh list from a
# call is appended to and dropped, on both runtimes. Ring does exactly the
# same thing with a temporary, so it is a row and not a hazard.

? "-- 1. another object's attribute, subscript-assigned --"
o1 = new Q
o1.aL[1] = 99
? "  o1.aL : " + Str(o1.aL)

? ""
? "-- 2. a METHOD's result --"
o2 = new Q
o2.L()[2] = 88
? "  o2.aL : " + Str(o2.aL)

? ""
? "-- 3. a plain function's result --"
$g = [1, 2, 3]
G()[3] = 77
? "  $g    : " + Str($g)

? ""
? "-- 4. add() through each of them --"
o3 = new Q
add(o3.aL, 4)
add(o3.L(), 5)
? "  o3.aL : " + Str(o3.aL)
add(G(), 4)
? "  $g    : " + Str($g)

? ""
? "-- 5. del() through each of them --"
o4 = new Q
del(o4.aL, 1)
del(o4.L(), 1)
? "  o4.aL : " + Str(o4.aL)

? ""
? "-- 6. insert() through a call's result --"
o5 = new Q
insert(o5.L(), 1, 0)
? "  o5.aL : " + Str(o5.aL)

? ""
? "-- 7. a NESTED path under a call's result --"
o6 = new Q
o6.M()[1][2] = 66
? "  o6.aM[1] : " + Str(o6.aM[1])

? ""
? "-- 8. a compound assignment through one --"
o7 = new Q
o7.L()[1] += 10
? "  o7.aL : " + Str(o7.aL)

? ""
? "-- 9. a FRESH list from a call is appended to and dropped --"
add(Fresh(), 9)
? "  Fresh() : " + Str(Fresh())

? ""
? "-- 10. and the original is untouched by a read of it --"
o8 = new Q
aCopy = o8.L()
aCopy[1] = 1000
? "  o8.aL : " + Str(o8.aL)
? "  aCopy : " + Str(aCopy)

? ""
? "done"

func G
	return $g

func Fresh
	return [1, 2]

func Str aL
	cS = ""
	for i = 1 to len(aL)
		cS += "" + aL[i] + " "
	next
	return cS

class Q
	aL = [1, 2, 3]
	aM = [[1, 2], [3, 4]]

	def L
		return aL

	def M
		return aM
