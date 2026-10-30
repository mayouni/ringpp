# Inside a brace whose object comes from a call, a bare call is the object's
# method if it has one, else the FUNCTION of that name -- a builtin included.
# Ring resolves the name before the arguments, so they are evaluated once.
aL = []
? "1 " + len(KQ().Days())
KQ() { ? "2 " + len(Days()) }
KQ() {
	? "3 " + len(Days())
	? "4 " + upper(Name())
	? "5 " + lower("ABC")
	aL = Days()
	add(aL, 9)
	? "6 " + len(aL)
}
# the object's own method of a builtin's name wins
LQ() { ? "7 " + len("abc") }
LQ() { ? "8 " + upper("x") }
# an argument is evaluated once
$nCalls = 0
KQ() { ? "9 " + len(Counted()) }
? "10 " + $nCalls
# a name that is neither: R3, caught
try
	KQ() { ? NoSuchThing(1) }
catch
	? "11 " + cCatchError
done
o = new K
o { ? "12 " + len(Days()) }
? "13 " + len(aL)

func KQ() return new K
func LQ() return new L
func Counted()
	$nCalls++
	return [1, 2]

class K
	def Days() return [1, 2, 3]
	def Name() return "k"

class L
	def len(x) return "L.len of " + x
	def upper(x) return "L.upper of " + x
