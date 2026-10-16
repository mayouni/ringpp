// classname(), including the case where the receiver's class is NOT
// known at compile time. The poison ranking made that the top item in
// Softanza: 60 functions fail on it and hold 5,508 others unusable.
//
// Ring's semantics, measured on 1.27 before any of this was written:
//   * an object      -> the class name, LOWERCASED
//   * a derived one  -> the CHILD's name, not the parent's
//   * anything else  -> the error "Bad parameter type!", NOT ""

func C1()
	o = new Thing
	return len(classname(o))

func C2()
	o = new Thing
	if classname(o) = "thing"
		return 1
	ok
	return 0

func C3()
	// through a parameter: nothing is provable here
	return nameOf(new Thing)

func C4()
	// the CHILD's name, not the parent's
	o = new Deeper
	return classname(o)

func C5()
	// a non-object RAISES. Answering "" would let a comparison against a
	// class name silently succeed, which is the one outcome worth more
	// than a missing feature.
	try
		x = classname(42)
		return "no error: " + x
	catch
		return "raised"
	done

func C6()
	// the guard Softanza actually uses. `and` short-circuits on Ring
	// 1.27, so classname is never reached for a non-object.
	if isObject(42) and classname(42) = "thing"
		return "matched"
	ok
	return "guarded"

func C7()
	// two classes down one path, so no single class can be folded in and
	// the runtime table is what answers
	n = 0
	a = new Thing
	b = new Deeper
	if classname(a) = "thing"
		n = n + 1
	ok
	if classname(b) = "deeper"
		n = n + 10
	ok
	return n

func nameOf(o)
	return classname(o)

class Thing

class Deeper from Thing
