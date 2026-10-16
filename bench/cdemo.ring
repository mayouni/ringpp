// Plain C, compiled by `zig cc` and loaded through the Ring++ native ABI.
// The C file this calls declares nothing about Ring++; the glue that makes
// these names callable was generated from its signatures.

func C1()
	if LoadLib("demo.dll") = 0
		return -1
	ok
	return add(20, 22)

func C2()
	LoadLib("demo.dll")
	return hypot2(3, 4)

func C3()
	LoadLib("demo.dll")
	return add(add(1, 2), add(3, 4))
