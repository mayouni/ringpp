// Which wins for a BARE call inside a method: the class's own method, or
// a global function of the same name?
//
// stzHashList's FindKey does `StzFindFirst(pcKey, Keys())` where `Keys`
// is BOTH `func Keys(paList)` at global scope and `def Keys()` on the
// class. Ring runs it; Ring++ used to bind the global, fail on arity,
// and hold 19,516 functions unusable.
//
// Measured on 1.27: the METHOD wins, on the name alone, and ARITY DOES
// NOT PARTICIPATE -- N3 is the case that proves it.

func N1()
	o = new Holder
	return o.CallBare()

func N2()
	o = new Holder
	return o.CallOnlyGlobal()

func N3()
	// the global takes one parameter, the method takes none, and a bare
	// call with no arguments still reaches the METHOD
	o = new Holder
	return o.CallArity()

func N4()
	o = new Holder
	return o.CallThis()

func N5()
	// inherited: the class itself has no Same(), its parent does, and a
	// bare call still must not fall through to the global
	o = new Child
	return o.CallBare()

func Same()
	return "GLOBAL"

func OnlyGlobal()
	return "GLOBAL ONLY"

func Arity(x)
	return "GLOBAL ARITY"

class Holder

	def Same()
		return "METHOD"

	def Arity()
		return "METHOD ARITY"

	def CallBare()
		return Same()

	def CallOnlyGlobal()
		return OnlyGlobal()

	def CallArity()
		return Arity()

	def CallThis()
		return This.Same()

class Child from Holder
