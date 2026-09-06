# A clean program whose only defect is a typo'd call. It is reportable only
# when the whole definition universe is visible -- and the unparseable draft
# next door takes that away from the entire run, not just from itself.
func main
	? Greet("world")

func Greet(cWho)
	return "hello " + cWho
