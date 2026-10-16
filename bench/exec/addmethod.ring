# addmethod, the four shapes, measured on 1.27: a PLAIN function becomes a
# method of the whole class, parameters as they are and `This` the object;
# an anonymous function the same; a METHOD's name, or a name that is
# nothing, does nothing at all -- so an alias made that way is R14 when
# called, on Ring and here. Softanza's alias engine is that last shape.

o = new K
o2 = new K
try addmethod(o, "Hi", "Hello")  catch ? "00 addmethod raised: " + cCatchError done
try ? "01 alias of a method: " + o.Hi()  catch ? "01 " + cCatchError done
? "01b ismethod hi " + ismethod(o, "hi")
try addmethod(o, "Plain", "PlainFunc")  catch ? "03 " + cCatchError done
try ? "04 a plain function with a parameter as a method: " + o.Plain(5)  catch ? "04 " + cCatchError done
try ? "04b on another object: " + o2.Plain(6)  catch ? "04b " + cCatchError done
try addmethod(o, "Who", "WhoAmI")  catch ? "05a " + cCatchError done
try ? "05 a plain function using This: " + o.Who()  catch ? "05 " + cCatchError done
try addmethod(o, "X", "NoSuchThing")  catch ? "06 " + cCatchError done
? "07 methods now " + len(methods(o))
for m in methods(o) ? "   " + m next
try addmethod(o, "Anon", func x { return "anon " + x })  catch ? "08 " + cCatchError done
try ? "09 an anonymous function as a method: " + o.Anon(7)  catch ? "09 " + cCatchError done

func PlainFunc n
	return "plain " + n

func WhoAmI
	return This.cName

class K
	cName = "k"
	def Hello
		return "hello from " + cName
	def Double n
		return n * 2
