# RUNG 5 OF THE RESIDENT VM: a method addmethod attached at run time survives the admissions after it -- a
# function, a new class, the class itself replaced. Until the class tables grew in place (rnxc.zig,
# growClassTables) the first class admission rebuilt them and the method was gone (R14). Run with
# `rnxc resident am_host.ring`; oracle_addmethod.ring is Ring's answer up to the replacement.
o = new Pet
addmethod(o, "Speak", "Bark")
? "before: " + o.Speak()
admitcode("f1", "func Other return 1" + nl)
? "after a function: " + o.Speak()
admitcode("c1", "class Cat" + nl + tab + "def Meow return 1" + nl)
? "after a new class: " + o.Speak()
replacecode("p1", "class Pet" + nl + tab + "name = " + char(34) + "rex" + char(34) + nl + tab + "def Hello return " + char(34) + "HELLO " + char(34) + " + name" + nl)
? "after Pet replaced: " + o.Speak() + ", " + o.Hello()

func Bark
	return "woof"

class Pet
	name = "rex"
	def Hello return "hello " + name
