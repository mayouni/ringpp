# An uncaught error three calls deep: Ring's report, byte for byte
# (measured 2026-09-11): the blank line, `Line N Error (Rk) : msg ` with
# its trailing space, `In function c() in file F` with the name lowercased,
# then one `Called from line L In function b() in file F` per caller,
# blank lines between, and the top level last with no newline after it.
? "start"
A()
func A
	B()
func B
	C()
func C
	x = 1 / 0
