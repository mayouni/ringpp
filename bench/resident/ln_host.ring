# RUNG 8 OF THE RESIDENT VM: a `new K` compiled before any admission defined
# K reaches K once one does -- Ring finds a class by NAME when the line runs.
# Every `new` below was compiled with this file, before ln_gadget.ring and
# ln_sub.ring were admitted. Run with `rnxc resident ln_host.ring`;
# ln_oracle.ring is Ring's answer up to the replacement.
? "host: start"

# before the class exists: R11, raised before the arguments are evaluated
try
	o = new Gadget(Say("never"))
	? "never printed"
catch
	? "before: " + cCatchError
done
try
	MakeGadget()
catch
	? "before, in a function: " + cCatchError
done

? "admit gadget: " + admitfile("ln_gadget.ring")
? "gadget: " + Show(MakeGadget())
? "top level: " + Show(new Gadget)
# no init (C-33): the object is made and the arguments do not run, as in
# compiled code -- Ring raises R3 `init` there
try
	? "no init: " + Show(MakeGadgetArgs("a"))
catch
	? "no init: " + cCatchError
done
? "widget: " + MakeWidget("w").Label()
? "widget, no parentheses: " + MakeWidgetBare().Label()
try
	MakeWidgetEmpty()
catch
	? "widget(): " + cCatchError
done
# the target holds the object before the arguments run (F-91)
? "early: " + EarlyWidget()
? "brace: " + Show(BraceGadget())
? "case: " + classname(MakeUpper()) + " " + classname(MakeLower())
try
	MakeFunc()
catch
	? "a function's name: " + cCatchError
done

? "admit sub: " + admitfile("ln_sub.ring")
s = MakeSub()
? "sub: " + Show(s) + ", twice " + s.Twice() + ", bumped " + Bumped(s)
? "classes: " + len(classes())

# Ring makes a variable of a name the brace's object lacks; here the class was
# unknown when the brace was compiled, so the name is its attribute: R12
try
	BraceUnknown()
	? "brace, a name the class lacks: no error"
catch
	? "brace, a name the class lacks: " + cCatchError
done

# the class REPLACED (rung 4): a late site makes the new class's objects
? "replace gadget: " + replacecode("gadget2", "class Gadget" + nl + tab + "nX = 100" + nl + tab + "cName = 'G'" + nl + "func Bump" + nl + tab + "nX += 10" + nl + "func SetX n" + nl + tab + "nX = n" + nl)
g = MakeGadget()
? "after: " + Show(g) + ", bumped " + Bumped(g)
? "sub after: " + Show(MakeSub())

# a late site in RELEASED code (rung 6): its name goes with it, and a class of
# that name admitted afterwards is reached by the code compiled then
? "admit late: " + admitcode("late1", "func MakeLater" + nl + tab + "return new Later" + nl)
try
	MakeLater()
catch
	? "later, before: " + cCatchError
done
? "release: " + releasecode("late1")
? "admit class: " + admitcode("later", "class Later" + nl + tab + "nZ = 3" + nl)
? "admit late again: " + admitcode("late2", "func MakeLater2" + nl + tab + "return new Later" + nl)
? "later: " + MakeLater2().nZ
# a later admission that brings, as a new name, the name of a class the program
# holds: the table must say so (RNXC_RESIDENT_CHECK compares it whole)
? "a name met again: " + admitcode("lname", "func LaterOf o" + nl + tab + "return o.later" + nl)
? "host: end"

func Say x
	? "say " + x
	return x

func Show o
	return classname(o) + "(" + o.nX + "," + o.cName + ")"

func MakeGadget
	return new Gadget

func MakeGadgetArgs x
	return new Gadget(Say(x))

func MakeWidget x
	return new Widget(Say(x))

func MakeWidgetBare
	return new Widget

func MakeWidgetEmpty
	return new Widget()

func EarlyWidget
	w = 7
	w = new Widget(w)
	return w.Label()

func BraceGadget
	o = new Gadget {
		nX = 5
		SetX(nX + 1)
		cName = "b"
	}
	return o

func BraceUnknown
	o = new Gadget {
		nNope = 1
	}
	return o

func MakeUpper
	return new GADGET

func MakeLower
	return new gadget

func MakeFunc
	return new MakeGadget

func MakeSub
	return new Sub

func Bumped o
	o.Bump()
	return o.nX
