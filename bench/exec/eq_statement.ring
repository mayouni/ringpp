# A statement whose `=` follows a literal, a list or a closing parenthesis is
# a COMPARISON on Ring: both sides run, the answer is dropped, the program
# goes on. Narrations write their expected values that way.
x = 5
? "1"
"good" + "ly" = "goodly"
? "2"
"a" = "b"
1 = 2
x + 1 = 6
? "3 x=" + x
(F()) = 3
F() + 1 = 3
[1, 2] = 3
"a" + "b" = H()
"q" = "q"
? "4 x=" + x
# a name read after it is still a read: R24 when nothing assigned it
try
	"good" + "ly" = "goodly" zzUnset
catch
	? "5 " + cCatchError
done
o = new K
o + 1 = 9
? "6 done"

func F
	? "  F ran"
	return 1

func H
	? "  H ran"
	return "ab"

class K
	def operator cOp, v
		? "  operator " + cOp + " " + v
		return 1
