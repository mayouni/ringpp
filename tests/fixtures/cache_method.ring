# A cached METHOD, end to end. The function before the class is deliberate:
# it is the shape where the grammar stops nesting a method's body inside the
# class node, and sibling-walking silently found nothing to check.
func Unused(x)
	return x

func main
	o = new T
	? "fib(28) = " + o.Slow(28)

class T
	nSeed = 5

	# Stateless: the object cannot change the answer, so it need not be in
	# the key. This.Slow() is a self-call, not a state read -- which is what
	# keeps a recursive method eligible, and recursion is where a cache pays.
	def Slow(n)   #rpp: cache
		if n < 2 return n ok
		return This.Slow(n-1) + This.Slow(n-2)
