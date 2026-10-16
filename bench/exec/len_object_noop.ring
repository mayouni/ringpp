# F-105. An object whose class has no `operator` cannot answer len():
# Ring raises R50 from inside len() -- `In len()` in front of the frame.
f()

func f
	o = new K
	? len(o)

class K
	x = 1
