# A program's own function may be named with a leading `@@` -- Softanza defines `@@`, `@@NL`, `@@S`, `@@SP`,
# `@@XT` -- and it is a function like any other: reached by name, listed, answered by isfunction. The compiler
# names its own synthetic functions `@@main`, `@@attrs`, `@@eval` and `@@lambda<n>`, which no program sees.
? isfunction("@@")
? isfunction("@@nl")
? isfunction("@@XT")
? isfunction("@@main")
aF = functions()
? find(aF, "@@") > 0
? find(aF, "@@nl") > 0
? find(aF, "@@main") > 0
cF = "@@"
? call cF(20)
cF = "@@NL"
? call cF("a")
? "" + @@(1) + @@nl("b") + @@XT()

func @@ x
	return x + 1

func @@NL c
	return c + "!"

func @@XT
	return "xt"
