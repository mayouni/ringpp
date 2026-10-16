# Ring's reflection builtins, measured on 1.27 first: ismethod, isfunction,
# methods, attributes, get/set/isattribute, functions, classes, globals,
# prevfilename, addattribute (PER OBJECT), addmethod (PER CLASS), ref and
# refcount. Softanza tests which methods an object answers, reads and
# writes attributes by name, and adds reactive properties at run time.
# `locals()` waits for eval's frame view and is left out.

o = new Child
? "01 ismethod " + ismethod(o, "Hello") + ismethod(o, "HELLO") + ismethod(o, "baseonly") + ismethod(o, "nope")
? "02 isfunction " + isfunction("MyFunc") + isfunction("myfunc") + isfunction("len") + isfunction("nope")
aM = methods(o)
? "03 methods " + len(aM)
for m in aM ? "   " + m next
aA = attributes(o)
? "04 attributes " + len(aA)
for a in aA ? "   " + a next
? "05 getattribute " + getattribute(o, "cName") + " " + getattribute(o, "NBASE")
try getattribute(o, "nope") catch ? "06 " + cCatchError done
setattribute(o, "cName", "changed")
? "07 setattribute -> " + o.cName
try setattribute(o, "nope", 1) catch ? "08 " + cCatchError done
? "09 isattribute " + isattribute(o, "cName") + isattribute(o, "nope")
aF = functions()
? "10 functions has myfunc: " + (find(aF, "myfunc") > 0) + "  first is a string: " + isString(aF[1])
aC = classes()
? "11 classes has child: " + (find(aC, "child") > 0) + (find(aC, "base") > 0)
aG = globals()
? "12 globals has o: " + (find(aG, "o") > 0) + "  count >= 5: " + (len(aG) >= 5)
? "13 prevfilename " + prevfilename()
? "14 from a function " + FromFunc()
try x = getattribute(5, "a") catch ? "15 " + cCatchError done
try x = methods("x") catch ? "16 " + cCatchError done
addattribute(o, "cExtra")
o.cExtra = "added"
? "17 addattribute -> " + o.cExtra + "  attributes now " + len(attributes(o))
o2 = new Child
? "18 another object has it: " + isattribute(o2, "cExtra")
addattribute(o, ["cA", "cB"])
? "19 list form: " + isattribute(o, "cA") + isattribute(o, "cB")
addmethod(o, "Added", "MyFunc")
? "20 addmethod -> ismethod " + ismethod(o, "Added") + "  on another object " + ismethod(o2, "Added")
? "21 calling it: " + o.Added()
aL = [1, 2, 3]
aR = ref(aL)
aR[1] = 99
? "22 ref: aL[1] " + aL[1] + "  aR[1] " + aR[1] + "  type " + type(aR)
? "23 refcount type " + type(refcount(aL))

func MyFunc
	return "myfunc ran"

func FromFunc
	return prevfilename()

class Base
	nBase = 5
	def BaseOnly
		return 1

class Child from Base
	cName = "child"
	nAge = 3
	def Hello
		return "hi"
	def World
		return "w"
