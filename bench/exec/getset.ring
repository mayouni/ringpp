# RING'S AUTOMATIC GETTERS AND SETTERS (F-73), measured on both 1.27
# builds: `o.x` calls getx() and `o.x = v` calls setx(v) when the object's
# class has them -- for ANY object except the method's own `This`, which
# always reads and writes its slots (vendor/ring-vm/src/vmvars.c:226). A
# brace from outside goes through them too; a brace inside a method of the
# object's own class does not (vmoop.c:770, callmethodinsideclass). A
# compound form reads through the getter and writes through the setter.
# The attribute must EXIST: a getter with no attribute is R12 (row 2).
#
# Softanza's chain of truth is written against it: `_(x).Is("Number")._`
# reads the attribute `_`, and its value is whatever get_() answers.

o = new K
? "1 read through getx: " + o.x
try
	? o.y2
catch
	? "2 a getter with no attribute: " + cCatchError
done
o.x = 7
? "3 write through setx, then read: " + o.x + " raw " + o.Raw()
? "4 This.x in a method: " + o.ThisX()
? "5 bare x in a method: " + o.BareX()
p = new K
? "6 another instance, in a method: " + o.OtherX(p)
j = new J
? "7 from another class's method: " + j.Peek(o)
o { ? "8 brace read: " + x }
o { x = 3 }
? "9 brace write, raw after: " + o.Raw()
o.x += 1
? "10 compound: raw " + o.Raw()
o.aL[1] = 55
? "11 element write through a getter: raw aL " + o.RawL()
c = new Child
? "12 inherited getter: " + c.x
aO = [o]
? "13 an object inside a list: " + aO[1].x
o.y = 9
? "14 setter only, raw after: " + o.y
? "15 magic underscore: " + o._
o.x = o.x + 1
? "16 read and write together, raw: " + o.Raw()
? "17 getter that reads This.x: " + o.z
? "18 a brace inside the class's own method: " + o.BraceSelf(p)
? "19 a brace inside another class's method: " + j.BraceOther(o)
? "20 This.x += 1: " + o.BumpThis()
? "21 eval of This.x: " + o.EvalThis()
? "22 eval of another's x: " + j.EvalOther(o)
? "23 attributes: " + len(attributes(o))
? "24 a plain function given a method's This: " + o.ViaFunc()
? "25 getattribute reads the slot: " + getattribute(o, "x")
addattribute(o, "w")
o.w = 3
? "26 an added attribute through its setter: raw " + o.RawW()
? "27 ...and through its getter: " + o.w
# A GETTER CALLED INSIDE AN eval STRING, while the eval holds temporaries:
# the call's window used to start where the eval's temporaries start, so
# the function name waiting in the first register was overwritten (R32).
? "28 eval: a call whose second argument is a getter: " + j.EvalCall(o)
? "29 eval: a method call whose second argument is a getter: " + j.EvalMCall(o)

func ReadX p
	return p.x

func Add a, b
	return "" + a + "+" + b

class K
	x = 5
	y = 1
	z = 0
	aL = [1, 2]
	_
	def getx
		return 42
	def setx(v)
		x = v * 2
	def sety(v)
		y = v + 100
	def gety2
		return "no attribute behind me"
	def getz
		return This.x + 1000
	def getaL
		return [9, 9]
	def get_
		return "one"
	def Raw
		return x
	def RawL
		return "" + aL[1] + "," + aL[2]
	def ThisX
		return This.x
	def BareX
		return x
	def OtherX(q)
		return q.x
	def BraceSelf(q)
		v = 0
		q { v = x }
		return v
	def BumpThis
		This.x += 1
		return x
	def EvalThis
		eval("r = This.x")
		return r
	def ViaFunc
		return ReadX(This)
	def getw
		return 77
	def setw(v)
		This.w = v * 10
	def RawW
		return This.w
	def Pair a, b
		return "" + a + "/" + b

class J
	def Peek(k)
		return k.x
	def BraceOther(k)
		v = 0
		k { v = x }
		return v
	def EvalOther(k)
		eval("r = k.x")
		return r
	def EvalCall(k)
		eval("r = Add(k.z, k.x)")
		return r
	def EvalMCall(k)
		eval("r = k.Pair(k.z, k.x)")
		return r

class Child from K
	def init
		x = 6
