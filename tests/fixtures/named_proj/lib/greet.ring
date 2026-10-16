# defaults imply named: :cEnd = "!" alone fills cGreeting from the default
#rpp: default cGreeting = "hello", cEnd = "."
func Greet(cName, cGreeting, cEnd)
	return cGreeting + ", " + cName + cEnd

# named with NO defaults: opt-in only, because a function written to
# receive the [name, value] pair Ring passes for :name = value would break
# if its calls were made positional behind its back
#rpp: named
func Area(w, h)
	return w * h
