#rpp: cache
func Fib(n)
	if n < 2 return n ok
	return Fib(n-1) + Fib(n-2)
