# A builtin's NAME read as a variable is R24 on Ring: a function name is not a value (F-47).
# The checker exempted every builtin name (F-133). Found when a model, told that
# floor() was not allowed, wrote `floor + 0.5` -- and the gate admitted it.
? Half(3.6)

func Half(n)
	nR = floor + 0.5
	return nR
