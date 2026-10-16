func Helper()
	return 1
func Outer()
	f = func { return Helper() }
	return call f()
