# F-102. Every line of an eval'd string is reported at the line of the eval
# CALL, inside the caller's function, and no `eval()` frame is shown: Ring
# runs the string after eval() has returned. Ring++ appends eval'd code past
# its line table, so an error inside it said `Line 0`, `in file F`, and every
# frame below it was lost. Here the string's third line calls g, which
# raises: g's frame, then `Called from` the eval's line In function f().
f()

func f
	eval("x = 1" + nl + "y = 2" + nl + "g()")

func g
	? "in g"
	? 1 + [1]
