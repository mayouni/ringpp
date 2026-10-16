load "typehints.ring"

int nTotal = Sum(3,4)
? "sum = " + nTotal

string cMsg = Greet("Mansour")
? cMsg

### does the annotation survive into the token stream?
st = ring_state_init()
aTok = ring_state_stringtokens(st, "int func sum(int x, int y)" + nl + "return x+y")
? "tokens: " + len(aTok)
for t in aTok
    ? "  [" + t[1] + "] " + t[2]
next
ring_state_delete(st)

int func Sum(int x, int y)
    return x + y

string func Greet(string cName)
    return "hello " + cName
