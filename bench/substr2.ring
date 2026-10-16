// substr(s, x) with two arguments wears two roles, chosen by x's TYPE:
// a string FINDS (returning a 1-based position, 0 when absent) and a
// number takes the SUFFIX from that position. Where the type cannot be
// proved at compile time, Ring decides when the call runs -- so Ring++
// does too, instead of refusing.
//
// Measured on 1.27 before this was built. S5 is the case that matters:
// the numeric-looking string "3" is a FIND, not a suffix, so the
// decision is the value's type and never its appearance.

func S1()
	// provable string: FIND
	return substr("hello world", "world")

func S2()
	// provable number: SUFFIX
	return substr("hello world", 3)

func S3()
	// not provable -- the value comes out of a list, as Softanza's own
	// `substr(pcHay, paNeedles[_i_])` does
	a = ["world"]
	return substr("hello world", a[1])

func S4()
	a = [3]
	return substr("hello world", a[1])

func S5()
	// a NUMERIC STRING is still a string: this FINDS "3", does not find
	// it, and answers 0 -- it is not the suffix from position 3
	a = ["3"]
	return substr("hello world", a[1])

func S6()
	// absent needle -> 0
	a = ["zzz"]
	return substr("hello world", a[1])

func S7()
	// past the end -> "", not an error. Measured through len() rather
	// than by concatenating: `"[" + substr(...) + "]"` needs `+` to know
	// at run time that its operands are strings, which is a DIFFERENT
	// gap (binary_expression, rank 8) and would make this case report on
	// something other than substr.
	a = [99]
	return len(substr("hello world", a[1]))

func S8()
	// neither string nor number: Ring raises
	a = [[1, 2]]
	try
		x = substr("hello world", a[1])
		return "UNEXPECTED " + x
	catch
		return cCatchError
	done
