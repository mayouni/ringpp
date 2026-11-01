# RUNG 4 OF THE RESIDENT VM: classes after the first file -- a class
# admitted while the program runs, one inheriting from it, and a class
# REPLACED while its objects exist (`replacecode`). Run with `rnxc resident
# cl_host.ring`; oracle_classes.ring is Ring's answer up to the replacement.
? "host: start"
? "admit shape: " + admitfile("cl_shape.ring")
o = NewShape(3)
? "made: " + Describe(o) + ", twice " + o.Twice()
? "admit square: " + admitfile("cl_square.ring")
s = NewSquare(4)
? "square: " + Describe(s) + ", twice " + s.Twice()
ci = NewCircle(4)
? "circle: super " + ci.Area2()
p = eval("return new Shape(5)")
? "by eval: " + Describe(p)
? "classes: " + len(classes()) + " " + classes()[len(classes())]

# a `new` compiled before the class existed finds it by name (rung 8), as Ring does
q = new Shape(6)
? "new before: " + Describe(q)

# the class REPLACED: every object already made answers with the new methods;
# the old Name and Twice stay; a new method; new initial values for new objects
? "replace shape: " + replacecode("shape2", "class Shape" + nl + tab + "nSide = 0" + nl + tab + "cKind = 'SHAPE'" + nl + "func init n" + nl + tab + "nSide = n" + nl + "func Area" + nl + tab + "return nSide * nSide * 10" + nl + "func Perimeter" + nl + tab + "return nSide * 4" + nl)
? "old object: " + Describe(o) + ", twice " + o.Twice() + ", perimeter " + o.Perimeter()
? "square inherits: " + Describe(s) + ", perimeter " + s.Perimeter() + "; circle: super " + ci.Area2()
? "new object: " + Describe(NewShape(1)) + ", " + Describe(NewSquare(2))
? "classes: " + len(classes()) + " " + classes()[len(classes())]

# a method replaced while it runs
? o.Grow()
? o.Grow()

# refusals: each raises, and the program is as it was
try
	replacecode("bad1", "class Shape" + nl + tab + "nSide = 0" + nl + tab + "cKind = ''" + nl + tab + "nExtra = 0" + nl)
	? "never printed"
catch
	? "layout: " + cCatchError
done
try
	replacecode("bad2", "class Shape from Tag" + nl + tab + "nSide = 0" + nl + tab + "cKind = ''" + nl)
	? "never printed"
catch
	? "parent: " + cCatchError
done
try
	replacecode("bad3", "class Shape" + nl + tab + "nSide = 0" + nl + tab + "cKind = ''" + nl + "func Area n" + nl + tab + "return n" + nl)
	? "never printed"
catch
	? "arity: " + cCatchError
done
try
	replacecode("bad4", "class Tag" + nl + tab + "cName = 'x'" + nl + "func init" + nl + tab + "cName = 'y'" + nl)
	? "never printed"
catch
	? "init: " + cCatchError
done
try
	replacecode("bad5", "class Empty" + nl + "? 'at new'" + nl + "func Hi" + nl + tab + "return 'HI'" + nl)
	? "never printed"
catch
	? "code at new: " + cCatchError
done
try
	admitcode("bad6", "class Shape" + nl + tab + "nSide = 0" + nl)
	? "never printed"
catch
	? "admit is not replace: " + cCatchError
done
? "still: " + Describe(o) + ", " + NewTag().Show() + ", " + NewEmpty().Hi()
? "host: end"
