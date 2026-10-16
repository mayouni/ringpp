// A wrong argument count is a RUN-time matter in Ring, not a compile-time
// one. Measured on 1.27 before this was built:
//
//   * a file containing a bad call compiles and runs
//   * an UNEXECUTED bad call costs nothing at all
//   * too few  -> "Error (R19) : Calling function with less number of parameters"
//   * too many -> "Error (R20) : Calling function with extra number of parameters"
//
// Ring++ refused these at compile time, which is stricter than Ring, and
// the poison ranking priced the strictness: one bad call in a branch
// nothing takes held 19,018 functions unusable.

func A1()
	// the bad call is present but never reached, so nothing happens and
	// the function around it is perfectly usable
	n = 0
	if n = 1
		return TwoParams(1)
	ok
	return "unreached, no error"

func A2()
	try
		x = TwoParams(1)
		return "UNEXPECTED " + x
	catch
		return cCatchError
	done

func A3()
	try
		x = TwoParams(1, 2, 3)
		return "UNEXPECTED " + x
	catch
		return cCatchError
	done

func A4()
	// the correct call still works, in the same function that contains
	// the wrong ones
	return TwoParams(20, 22)

func TwoParams(a, b)
	return a + b
