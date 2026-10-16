# `n++` AS A VALUE, and RING'S POSTFIX SYNTAX HAS PRE-INCREMENT SEMANTICS.
#
# It increments and yields the NEW value. Measured on 1.27 before a line of
# it was written -- the statement form's comment in the compiler had said
# this "would need Ring's pre/post distinction pinned down first, and it is
# not written that way in Softanza", and both halves were wrong:
# `This.MatchAt(_cStr_, _nStart_++)` in stzRegex is exactly that shape.
#
# Row 4 is the one that pins the ORDER as well as the value: `j++ + j++`
# with j at 5 is 13, which is 6 + 7 and nothing else.
#
# WHAT IT DOES NOT COVER, and the refusal says so: a SUBSCRIPT target as a
# value. `a[i]++` would have to evaluate `i` twice -- once to increment and
# once to read back -- and wherever the index has a side effect that is a
# silent wrong answer. The estate has no such site, so the narrow rule is
# the correct one.

? "-- 1. assigned: BOTH are the new value --"
n = 5
x = n++
? "  x = " + x + "   n = " + n

? ""
? "-- 2. printed --"
m = 5
? "  " + m++
? "  m = " + m

? ""
? "-- 3. in arithmetic, with the increment on the RIGHT of a string --"
k = 5
? "  'a' + k++ : " + ("a" + k++)
? "  k = " + k

? ""
? "-- 4. twice in one expression, which pins the order --"
j = 5
? "  j++ + j++ : " + (j++ + j++)
? "  j = " + j

? ""
? "-- 5. as an ARGUMENT --"
p = 5
? "  Show(p++) : " + Show(p++)
? "  p = " + p

? ""
? "-- 6. and `--` the same way --"
e = 5
? "  Show(e--) : " + Show(e--)
? "  e = " + e

? ""
? "-- 7. on a GLOBAL, which is where the register bug lived --"
$g = 5
? "  1 + $g++ : " + (1 + $g++)
? "  $g = " + $g

? ""
? "-- 8. on an ATTRIBUTE --"
o = new K
? "  o.Bump() : " + o.Bump()
? "  o.Bump() : " + o.Bump()

? ""
? "done"

func Show(v)
	return "<" + v + ">"

class K
	@n = 0

	def Bump()
		return "" + @n++
