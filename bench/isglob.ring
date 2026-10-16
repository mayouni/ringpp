// isGlobal(cName) -- 1 if that global has been ASSIGNED by now.
//
// Measured on 1.27 first. The case that decides the design is G5:
// `$gNull = NULL` still answers 1, so the question is whether the global
// EXISTS, not whether its value is anything. Answering from the slot's
// value would re-run every initialise-once guard in Softanza on a global
// somebody had deliberately set to NULL.
//
// Softanza calls this exactly three times, always as isGlobal(:$Name),
// and always to initialise a global only if it is not there yet.

$gSet = 5
$gNull = NULL
$gEmpty = ""

func G1()
	return isGlobal(:$gSet)

func G2()
	// a name that is no global anywhere
	return isGlobal("$gNeverAssignedAnywhere")

func G3()
	// case-insensitive, like every other Ring identifier
	return isGlobal("$GSET")

func G4()
	// visible from inside a function, not just at the top level
	return helper()

func G5()
	// assigned NULL: the global EXISTS
	return isGlobal(:$gNull)

func G6()
	// assigned "": also exists
	return isGlobal(:$gEmpty)

func G7()
	// the guard Softanza actually writes
	if NOT isGlobal(:$gSet)
		return "would initialise"
	ok
	return "already there"

func helper()
	return isGlobal(:$gSet)
