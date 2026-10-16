# F-102, for a builtin compiled to its own opcode rather than a `bcall`:
# del() is `vdel`, and Ring still reports `In del() In function f()`.
f()

func f
	del(5, 1)
