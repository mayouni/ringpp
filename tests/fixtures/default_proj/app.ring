# Default parameters through `ringpp build`, in the ORDINARY shape: the
# default is declared in the library, the short calls sit here. A single
# file cannot honour a default it did not declare; the build can, because it
# stages the whole load closure and collects every declaration first.
load "lib/greet.ring"

func main
	? Greet("Mansour")
	? Greet("Mansour", "salam")
	? Greet("Mansour", "salam", "!")
	? Sum()
