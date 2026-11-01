# RUNG 6 OF THE RESIDENT VM: a running program RELEASES the code it admitted
# -- its functions, globals, constants and names gone, the program as it was
# before it. Only the LAST admission (a stack), and not one that defined a
# class or a lambda or replaced anything, nor while its code runs. Run with
# `rnxc resident rl_host.ring`; Ring has nothing to compare with -- golden.
? "host: start"
Q = char(34)
oObj = new RlObj

# admit, call, release: the function is gone and its name free again
? "admit: " + admitcode("req", "$nReq = 1" + nl + "func Handle c" + nl + tab + "return " + Q + "one " + Q + " + c" + nl)
? "call: " + Handle("a")
? "release: " + releasecode("req")
try
	? Handle("b")
catch
	? "called after: " + cCatchError
done
try
	cName = "Handle"
	? call cName("b")
catch
	? "by name after: " + cCatchError
done
try
	eval("? Handle(" + Q + "e" + Q + ")")
catch
	? "eval after: " + cCatchError
done
? "the name again: " + admitcode("req", "func Handle c" + nl + tab + "return " + Q + "two " + Q + " + c" + nl)
? "call: " + Handle("c")

# what the host kept outlives the code that made it
? "admit: " + admitcode("maker", "func MakeText return " + Q + "a literal of the released code" + Q + nl + "func MakeList return [1, 2, " + Q + "x" + Q + "]" + nl)
cKept = MakeText()
aKept = MakeList()
? "release: " + releasecode("maker")
? "kept text: " + cKept
? "kept list: " + len(aKept) + " " + aKept[3]

# only the last: a stack
? "admit a: " + admitcode("a", "func FA return 1" + nl)
? "admit b: " + admitcode("b", "func FB return 2" + nl)
try
	releasecode("a")
catch
	? "a before b: " + cCatchError
done
? "release b: " + releasecode("b")
? "release a: " + releasecode("a")
? "release req: " + releasecode("req")

# a file, by its path
? "admit file: " + admitfile("rl_lib.ring")
? "lib: " + LibAnswer()
? "release file: " + releasefile("rl_lib.ring")
try
	? LibAnswer()
catch
	? "lib after: " + cCatchError
done

# a name the released code brought: asked of an object before and after
? "admit fresh: " + admitcode("fresh", "func FreshName return 1" + nl)
? "fresh, a method of the host's object: " + ismethod(oObj, "freshname")
? "release fresh: " + releasecode("fresh")
? "after: " + ismethod(oObj, "freshname")

# a function that read a name bare, released: a global of that name is
# admitted after it, where it was refused while the function was there
? "admit reader: " + admitcode("reader", "func ReadsLater return zLater" + nl)
try
	admitcode("early", "zLater = 4" + nl)
catch
	? "a global while it reads: " + cCatchError
done
? "release reader: " + releasecode("reader")
? "a global after: " + admitcode("later", "zLater = 5" + nl)

# a global the released code made: its place is free, and EMPTY, for the next
? "admit g: " + admitcode("g", "$gOld = 41" + nl)
? "release g: " + releasecode("g")
? "admit h: " + admitcode("h", "func ReadNew return $gNew" + nl + "if false" + nl + tab + "$gNew = 1" + nl + "ok" + nl)
try
	? ReadNew()
catch
	? "a new global in its place: " + cCatchError
done
? "release h: " + releasecode("h")

# a getter's name the released code brought (getnv, for RlObj's nV): gone with
# it, so the name that takes its place is not a getter of nV
? "admit acc: " + admitcode("acc", "func AskObj o return o.getnv()" + nl)
? "release acc: " + releasecode("acc")
? "admit brand: " + admitcode("brand", "func AskObj o return o.brand()" + nl)
addmethod(oObj, "brand", "BrandFn")
? "nV after: " + oObj.nV
? "release brand: " + releasecode("brand")
# the host's addmethod survives the name's release, and answers when it is back
? "the name back: " + admitcode("brand2", "func AskBrand o return o.brand()" + nl)
? "brand after: " + AskBrand(oObj)
? "release brand2: " + releasecode("brand2")

# an eval compiled while the released code was there: not run again after it
? "admit ev: " + admitcode("ev", "func EvX return 1" + nl)
? "eval before: " + EvalA()
? "release ev: " + releasecode("ev")
? "eval after: " + EvalB() + EvalA()

# not while its code runs
? "admit self: " + admitcode("self", "func SelfRelease" + nl + tab + "return releasecode(" + Q + "self" + Q + ")" + nl)
try
	SelfRelease()
catch
	? "from inside itself: " + cCatchError
done
? "release self from the host: " + releasecode("self")

# a function of it attached to a class by addmethod: the class would reach it
? "admit att: " + admitcode("att", "func AttFn return 7" + nl)
addmethod(oObj, "attached", "AttFn")
? "attached: " + oObj.attached()
try
	releasecode("att")
catch
	? "attached by addmethod: " + cCatchError
done

# what cannot be released, and the stack it clears
? "admit keep: " + admitcode("keep", "func FKeep return 1" + nl)
? "admit lam: " + admitcode("lam", "fLam = func x { return x * 2 }" + nl)
try
	releasecode("lam")
catch
	? "lambda: " + cCatchError
done
try
	releasecode("keep")
catch
	? "under it: " + cCatchError
done
? "admit cls: " + admitcode("cls", "class RlK" + nl + tab + "def V return 1" + nl)
try
	releasecode("cls")
catch
	? "class: " + cCatchError
done
? "admit f: " + admitcode("f", "func FRep return 1" + nl)
? "replace f: " + replacecode("frep", "func FRep return 2" + nl)
try
	releasecode("frep")
catch
	? "replacement: " + cCatchError
done

# a program fed code for ever stays its size: 500 rounds of admit, call, release
nSum = 0
for i = 1 to 500
	admitcode("round", "func Round n" + nl + tab + "return n + " + i + nl)
	nSum += Round(0)
	releasecode("round")
next
? "500 rounds: " + nSum
? "host: end"

func BrandFn return 99
func EvalA return eval("return " + char(34) + "A" + char(34))
func EvalB return eval("return " + char(34) + "B" + char(34))

class RlObj
	nV = 3
	def Hello return 1
	# so that zLater is a name the program had before the reader came
	def zLater return 0
