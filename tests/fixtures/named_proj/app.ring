# Named arguments through `ringpp build`, in the ORDINARY shape: opted in by
# the library, used by the entry. Every call here is a different placement,
# and the package is RUN so the answers, not the text, are the assertion.
load "lib/greet.ring"

func main
	? Greet("Mansour", :cEnd = "!")
	? Greet(:cName = "Mansour", :cGreeting = "salam")
	? Greet("Mansour", :cGreeting = "hi", :cEnd = "?")
	? Area(:w = 3, :h = 4)
