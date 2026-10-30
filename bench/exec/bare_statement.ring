# A list, a literal, a parenthesis, a subscript, a member or a unary on a
# line of its own is evaluated and dropped on Ring, and the program goes on.
x = 5
aL = [1, 2]
o = new K
? "1"
[:natural = "uppercase", :semantic = "METHOD_UPPERCASE"]
[1, F()]
? "2"
"abc"
42
? "3"
(F())
aL[1]
o.v
? "4"
-x
? "5 x=" + x
? "6"
try
	[zzUnset]
catch
	? "7 " + cCatchError
done
? "8 done"

func F
	? "  F ran"
	return 1

func G
	? "  G ran"
	return 2

class K
	v = 1
