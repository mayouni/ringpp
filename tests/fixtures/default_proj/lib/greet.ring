#rpp: default cGreeting = "hello", cEnd = "."
func Greet(cName, cGreeting, cEnd)
	return cGreeting + ", " + cName + cEnd

# every parameter defaulted: a ZERO-argument call has no `arguments` node at
# all in the tree, and the first draft mishandled exactly that
#rpp: default a = 40, b = 2
func Sum(a, b)
	return a + b
