# F-102. The builtin's name comes first, then the Ring frames: `In find()
# In method m() in file F`, then the callers. A CAUGHT error shows no
# frames at all, so the two caught rows print the same on both builds
# before and after; the uncaught one at the end is what the probe pins.
try
	? lower(5)
catch
	? "caught: " + cCatchError
done
try
	? number("abc")
catch
	? "caught: " + cCatchError
done
g()

func g
	o = new K
	o.M()

class K
	def M
		? find(3, 1)
