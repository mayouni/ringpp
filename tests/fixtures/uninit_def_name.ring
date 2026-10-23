# A function's or a class's NAME read as a variable is R24 on Ring (F-47): a name is not a value.
# The checker exempted every name the program defines (F-133), so a model's `zerolist[x] = 0`
# inside func ZeroList was admitted by the gate.
? F(1)
? H(1)

func F(n)
	x = G + 1
	return x

func H(n)
	y = Box
	return 1

func G()
	return 2

class Box
	n = 1
