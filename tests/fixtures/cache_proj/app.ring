# The build integration's gate: a program in TWO files, the anchor in the
# loaded one. Ring resolves a relative load against the working directory,
# so this shape is the one that proves the staged closure keeps its layout
# and that the compile runs from inside it.
load "lib/math.ring"

func main
	? "fib(28) = " + Fib(28)
