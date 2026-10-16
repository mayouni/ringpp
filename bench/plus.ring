// `+` is chosen by the LEFT operand's type and IS NOT SYMMETRIC.
// Measured on 1.27 before any of this was built:
//
//   number + number / numeric string  -> add
//   number + non-numeric string       -> R41 Invalid numeric string
//   number + list                     -> R21 incorrect type
//   string + anything but a list      -> concatenate
//   string + list                     -> R21
//   list   + anything                 -> APPEND AS ONE ITEM, and the left
//                                        list is MUTATED: [1,2]+[3,4] is
//                                        len 3, not len 4
//
// Every one of these compiled and then PANICKED before this probe existed:
// `add: not a number`. The census could not see it, because the census
// measures compiling and this dies at run time.

func B1()
	c = "ab"
	d = "cd"
	return c + d

func B2()
	c = "ab"
	n = 3
	return c + n

func B3()
	// a whole float loses its decimals, a fractional one keeps two
	c = "x"
	return c + 1.5

func B4()
	c = "x"
	return c + 3.0

func B5()
	// number + NUMERIC string adds
	n = 3
	e = "5"
	return n + e

func B6()
	// string + number concatenates, the other way round
	e = "5"
	n = 3
	return e + n

func B7()
	// number + non-numeric string raises
	n = 3
	c = "ab"
	try
		x = n + c
		return "UNEXPECTED " + x
	catch
		return cCatchError
	done

func B8()
	// list + list APPENDS the right list as ONE item
	a = [1, 2]
	r = a + [3, 4]
	return len(r)

func B9()
	// ...and the appended item is itself a list. Measured through len()
	// rather than type(), which Ring++ does not have yet -- using it here
	// would make this case report on a missing builtin instead of on `+`.
	a = [1, 2]
	r = a + [3, 4]
	return len(r[3])

func B10()
	// the LEFT list is mutated in place
	a = [1, 2]
	r = a + 9
	return len(a)

func B11()
	// number + list raises
	n = 3
	a = [1, 2]
	try
		x = n + a
		return "UNEXPECTED"
	catch
		return cCatchError
	done

func B12()
	// string + list raises
	c = "ab"
	a = [1, 2]
	try
		x = c + a
		return "UNEXPECTED"
	catch
		return cCatchError
	done

func B13()
	// a CHAINED append as a statement: the left side of the outer `+` is
	// itself an expression, not a name. Both appends must land on the
	// same list -- if copy-on-write clones between them, the second is
	// silently lost and this returns 3 instead of 4.
	a = [1, 2]
	a + [3, 4] + [5, 6]
	return len(a)

func B14()
	a = [1, 2]
	a + [3, 4] + [5, 6]
	return len(a[4])

// B15-B17: found by rpp/tui.ring's Text on 2026-09-03, one ordinary line.
// B15 gave "||": expr() used the target register as the accumulator, so
// substr(s, 2) read the partial. B16 panicked in release(): every `+` was
// classified int, so a local holding a concatenation was uncounted while
// its strings were counted. B17 is the left-literal shape of B15.
func B15()
	s = "abc"
	s = left(s, 1) + "|" + substr(s, 2)
	return s

func B16()
	a = [ "abc" ]
	s = a[1]
	s = left(s, 1) + "|" + substr(s, 2)
	return s + "/" + a[1]

func B17()
	s = "abc"
	s = "<" + s + ">"
	return s

// B18-B20: the chain, 2026-09-08. `a + 2 + 3` appends BOTH on Ring (len 3,
// last 3), a chain through a nested path lands on the same inner list, and
// a chain whose head is not a place -- a string literal -- mutates nothing.
func B18()
	a = [1]
	a + 2 + 3
	return len(a) * 10 + a[len(a)]

func B19()
	a = [[1], [2]]
	a[2] + 7 + 8
	return len(a[2]) * 10 + a[2][3]

func B20()
	s = "x"
	"[" + s + "]"
	return s
