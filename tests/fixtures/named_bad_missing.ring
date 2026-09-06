# Area(5) leaves h with neither an argument nor a default. Under plain Ring
# that is R19 at the call; Ring++ refuses it at the declaration's terms,
# naming the parameter, before anything is built.
#rpp: named
func Area(w, h)
	return w * h

func main
	? Area(5)
