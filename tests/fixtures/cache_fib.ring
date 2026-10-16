# The transform's end-to-end gate. Ring runs the OUTPUT of `ringpp cache`
# and must print the same number a plain recursive fib prints -- a cache
# that is fast and wrong is the failure mode this feature has to rule out.

#rpp: cache
func Fib(n)
	if n < 2 return n ok
	return Fib(n-1) + Fib(n-2)

func main
	? Fib(28)
