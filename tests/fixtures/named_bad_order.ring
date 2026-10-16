# A positional argument AFTER a named one has no position to go to.
#rpp: named
func Area(w, h)
	return w * h

func main
	? Area(:w = 3, 4)
