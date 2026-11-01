# RUNG 2 OF THE RESIDENT VM: a running program admits more source into itself
# and goes on to call it -- the loop HaroServer's host runs. Run with
# `rnxc resident in_host.ring`; on Ring, oracle_inside.ring stands eval(read())
# in for admitfile() to say what Ring answers where it can.
? "host: start"

# a file, and at once a function it defines -- compiled before it existed
? "admit lib: " + admitfile("in_lib.ring")
? "lib says: " + Greet("Ring++")

# source the program built, under a name
cCode = "func Square n" + nl + tab + "return n * n" + nl
? "admit code: " + admitcode("square", cCode)
? "7 squared: " + Square(7)

# a refusal is an error the host catches, and the program is as it was
try
	admitfile("in_bad.ring")
	? "never printed"
catch
	? "refused: " + cCatchError
done
? "after the refusal: " + isFunction("badgood") + " " + Greet("again")

# an admission inside an admission
? "admit outer: " + admitfile("in_outer.ring")
? "inner, from the host: " + Inner()

# eval reaches what was admitted, and cannot admit
eval("? 'eval: ' + Square(3)")
try
	eval("admitfile('in_lib.ring')")
catch
	? "inside eval: " + cCatchError
done

# the same file twice, and a function defined again
try
	admitfile("in_lib.ring")
catch
	? "twice: " + cCatchError
done
try
	admitcode("again", "func Square n" + nl + tab + "return 0" + nl)
catch
	? "redefined: " + cCatchError
done
? "Square still: " + Square(4)

# a call compiled before its function exists, to a name that begins with `@@` -- Softanza's own `@@`,
# `@@NL`, `@@S` are -- reaches it once an admission defines it, as any late call does
admitcode("atat", "func @@Twice x" + nl + tab + "return x * 2" + nl)
? "a late @@ name: " + AtTwice()

# from inside a function, deep in the call stack
? "from a function: " + AdmitIn(3)
# LAST, because on Ring the program ends without a word after it (C-21's family):
# an admitted top level that raises: the error reaches the host's try, its functions stay
try
	admitfile("in_raises.ring")
catch
	? "its top level raised: " + cCatchError
done
? "its function stays: " + Stays()

? "host: end"

func AdmitIn n
	if n > 1
		return AdmitIn(n - 1)
	ok
	admitcode("deep", "func Deep" + nl + tab + "return 42" + nl)
	return Deep()

func AtTwice
	return @@Twice(21)
