# A dynamic `call x(...)` resolves its target at run time, so no call-site
# rewrite can reach it. A file with one cannot have defaults honoured for
# every call, and is REFUSED rather than half-served.
#rpp: default b = 2
func F(a, b)
	return a + b

func main
	c = "F"
	? call c(1, 2)
	? F(1)
