# A COMPOUND ASSIGNMENT AND RING'S ACCESSORS (F-73), measured on both 1.27
# builds with getx() answering 42 and setx(v) storing v * 2. Through This
# a compound READS THROUGH THE GETTER and WRITES THE SLOT: This.x += 1
# leaves x at 43, This.x *= 2 at 84. Written out, This.x = This.x + 1
# reads the slot (6), and so does a bare x += 1. A setter-only attribute
# through This never reaches its setter (2); from outside, o.y += 1
# does (102). Ring++ refused every compound on a member until 2026-09-26.

o = new K
? "a This.x += 1: " + o.A()
o.Reset()
? "b This.x = This.x + 1: " + o.B()
o.Reset()
? "c bare x += 1: " + o.C()
o.Reset()
? "d This.y += 1 (setter only): " + o.D()
o.Reset()
? "e This.x -= 1: " + o.E()
o.Reset()
? "f o.y += 1 from outside (setter only): "
o.y += 1
? "  raw y " + o.RawY()
o.Reset()
? "g This.x *= 2: " + o.G()

class K
	x = 5
	y = 1
	def getx
		return 42
	def setx(v)
		x = v * 2
	def sety(v)
		y = v + 100
	def Reset
		x = 5
		y = 1
	def RawY
		return y
	def A
		This.x += 1
		return x
	def B
		This.x = This.x + 1
		return x
	def C
		x += 1
		return x
	def D
		This.y += 1
		return y
	def E
		This.x -= 1
		return x
	def G
		This.x *= 2
		return x
