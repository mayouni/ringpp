# F-102. classname() is the `clsname` opcode, which reported `In raise()`
# for its bad argument -- the origin Ring prints for raise() and nothing
# else. Ring says `In classname()`.
f()

func f
	? classname(5)
