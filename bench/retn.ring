// `return This.X() = 0` -- Softanza's commonest predicate shape, and the
// largest single refusal class in the corpus until 2026-09-04.
//
// It parses as a BARE `return` plus an orphaned `This.X() = 0`, and the
// orphan is a SIBLING of the function definition in the tree. The part
// walk puts it back inside the function and emitOne rejoins the two, so
// the ATTRIBUTION was never wrong -- what was wrong is that nothing could
// compile the expression: cond() had no case for an assignment_expression,
// its fallback called expr(), expr() called binary(), binary() sent `=`
// back to cond(), and the three recursed until the register file ran out.
//
// R4/R5 are the hazard this was feared to be: a predicate MUST NOT run as
// an attribute initialiser at construction. They check the attributes are
// what the class declared, with a predicate of exactly this shape sitting
// between them.
$rn = 0

func R1()
	return RnZero() = 0

func R2()
	return len([1, 2]) = 2

func R3()
	o = new RetnK
	return o.IsEmpty()

// the attributes must survive a predicate defined among them
func R4()
	o = new RetnK
	return o.Count()

func R5()
	o = new RetnK
	return o.Tag()

func RnZero()
	return 0

class RetnK
	@n = 3
	@tag = "kept"

	def IsEmpty()
		return This.Count() = 0

	def Count()
		return @n

	def Tag()
		return @tag
