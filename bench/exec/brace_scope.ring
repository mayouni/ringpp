# F-124. Inside `obj { ... }` Ring's object scope is the BRACE OBJECT's:
# a bare name is a local or that object's attribute, never the enclosing
# method's attribute; a bare call is that object's method or a global
# function, never the enclosing class's method; and `self` is the brace
# object while `This` stays the method's. Ring++ took the method's own
# attributes and methods first, so a brace inside a method wrote self.x
# where Ring makes a local, read an attribute where Ring raises R24, and
# called the class's method where Ring calls the function. A census of
# Softanza's base and max units with a traced build found no site of any of
# these shapes. Measured on both 1.27 builds 2026-10-14, every row the same
# on both. Not here, and named: a brace's bare write to an attribute added
# at run time (addattribute), which Ring writes and Ring++ makes a local.

o2 = new Pt
o2 { self.q = 7 }
? "2 self in a top-level brace is the brace object: " + o2.q
F()
p = new Host
p.Run()
? "10 the host after Run: x=" + p.x + " y=" + p.y

func F
	o3 = new Pt
	o3 { self.q = 8 }
	? "3 self in a brace inside a function: " + o3.q
	o4 = new Pt
	o4 { q = 9 }
	? "4 bare write of the object's attribute, in a function: " + o4.q

func Hello
	return "function hello"

class Pt
	q = 0

class Host
	x = 10
	y = 20
	func Run
		new Pt {
			x = 100
			q = 5
		}
		? "5 after a brace wrote x: self.x = " + self.x + ", x = " + x
		try
			new Pt { ? "6 read of the method's attribute in a brace: " + y }
		catch
			? "6 read of the method's attribute in a brace raised: " + cCatchError
		done
		new Pt { ? "7 bare call the brace object lacks: " + Hello() }
		try
			new Pt { ? "8 the method's own method, bare: " + Hello2() }
		catch
			? "8 the method's own method, bare, raised: " + cCatchError
		done
		new Pt { ? "9 This in a brace: " + classname(This) + ", self: " + classname(self) }
		This { ? "9b a brace on This sees its attributes: x=" + x + " " + Hello2() }
	func Hello
		return "method hello"
	func Hello2
		return "method hello2"
