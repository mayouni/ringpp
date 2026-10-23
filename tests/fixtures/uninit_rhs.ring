# The right-hand side of an assignment, when it is a bare name nothing assigns, is read at
# run time: R24. The checker never looked at a right-hand side that was a lone name.
? Read()

func Read()
	x = nTypo
	return x
