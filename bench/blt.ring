// The builtin batch, A/B'd against Ring 1.27.
//
// These were not chosen from Ring's manual. They are what RUNNING
// Softanza asked for: the builtins it calls that this VM lacked, after
// discarding the 60 names Softanza defines itself (a user function
// shadows a builtin, measured -- so those calls never reach here).
//
// Anything whose value varies per run -- clock, currentdir, random -- is
// tested on an INVARIANT, never on a value, or the probe would be
// comparing two clocks and calling the difference a bug.

func T1()
	return pow(2, 10)

func T2()
	return exp(0) + log(1) + log10(100)

func T3()
	return sin(0) + cos(0) + tan(0)

func T4()
	return asin(0) + acos(1) + atan(0) + atan2(0, 1)

func T5()
	return sinh(0) + cosh(0) + tanh(0)

func T6()
	// a value with a fraction, so this checks the arithmetic and not
	// just the zero cases
	return pow(2, 0.5) * 1000000

func T7()
	return log10(1000) + pow(3, 3)

func T8()
	// clock() varies, so the invariant is that it is a number that does
	// not go backwards
	n1 = clock()
	n2 = clock()
	if n2 >= n1
		return "monotonic"
	ok
	return "went backwards"

func T9()
	return clockspersecond()

func T10()
	return direxists(".")

func T11()
	return direxists("no_such_directory_zzz")

func T12()
	// the path varies; that it is a non-empty string does not
	if len(currentdir()) > 0
		return "has a cwd"
	ok
	return "empty"

func T13()
	if len(exefolder()) > 0
		return "has an exefolder"
	ok
	return "empty"

func T14()
	// random(n) is 0..n INCLUSIVE -- verified on 1.27, where five calls
	// to random(10) produced a 0. Tested as a range, not a value.
	bOk = 1
	for i = 1 to 50
		r = random(10)
		if r < 0 or r > 10
			bOk = 0
		ok
	next
	return bOk

func T15()
	return random(0)

func T16()
	return nothing()

func T17()
	g = str2list("a" + nl + "b" + nl + "c")
	return len(g)

func T18()
	g = str2list("a" + nl + "b" + nl + "c")
	return g[3]

func T19()
	return version()

func T20()
	// srandom seeds; the useful invariant is that it does not blow up
	// and that random still answers in range afterwards
	srandom(42)
	r = random(5)
	if r >= 0 and r <= 5
		return "seeded"
	ok
	return "out of range"

func T21()
	return iswindows() + iswindows64()

func T22()
	return islinux() + ismacosx() + isfreebsd() + isunix() + isandroid() + ismsdos()
