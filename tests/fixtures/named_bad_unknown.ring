# :hh is not a parameter of Area. Under plain Ring this passes the pair
# ["hh", 4] into h and computes 3 * ["hh",4] -- a wrong program that runs.
# Ring++ refuses it by name.
#rpp: named
func Area(w, h)
	return w * h

func main
	? Area(3, :hh = 4)
