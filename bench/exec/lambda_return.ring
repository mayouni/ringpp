$fSub = func t { return t - 1 }
$nX = 3

# 1  a one-parameter lambda returned directly: the grammar reads `func t {` after a bare `return` as a definition
f1 = Mk1()
? "1 " + type(f1) + " " + call f1(5)

# 2  with dead code after it, and the function's next definition on the following rows
f2 = Mk2()
? "2 " + call f2(5)

# 3  two of them in one function, the first inside an `if`
f3a = Mk3(1)
f3b = Mk3(0)
? "3 " + call f3a(5) + " " + call f3b(5)

# 4  a multi-line body with a comment and a global
f4 = Mk4()
? "4 " + call f4(5)

# 5  in a method
o = new K
f5 = o.Make()
? "5 " + call f5(5)

# 6  the body calls a global lambda
f6 = Mk6()
? "6 " + call f6(5)

# 7  the other spellings, which always read right
f7a = Mk7a()
f7b = Mk7b()
f7c = Mk7c()
? "7 " + call f7a(1) + " " + call f7b(1, 2) + " " + call f7c(3)

# 8  the lambda is not the last thing in the file: a function after it still runs
? "8 " + Last()

#
# `return func t { ... }` -- a lambda written straight after `return`, with ONE parameter and no parentheses -- was read by the grammar as a bare `return` and a
# function definition named `t`, so the enclosing function returned the empty string and a function `t` appeared (Ring++ 2026-10-05: `call f(1)` was R3, "Calling
# Function without definition:", with an empty name; `rnxc dis` said `ret=str`). `return func(t) {`, `return func a, b {`, and the same line inside an `if` were
# always read right. Every row is the oracle's answer and official 1.27's. (A lambda that captures a LOCAL of its defining function is not here: Ring cannot see it, R24,
# and Ring++ can -- the registered divergence C-2 to C-5 in bench/ab-known.txt.)

func Mk1()
	return func t { return t + 1 }

func Mk2()
	return func t { return t * 2 }
	? "dead"

func Mk3(n)
	if n = 1
		return func t { return t + 100 }
	ok
	return func t { return t + 200 }

func Mk4()
	return func t {
		# a comment inside the body
		y = t + $nX
		return y * 2
	}

func Mk6()
	return func t { return call $fSub(t) * 10 }

func Mk7a()
	return func(t) { return t + 1 }

func Mk7b()
	return func a, b { return a + b }

func Mk7c()
	return (func t { return t * 3 })

func Last()
	return "last"

class K
	func Make()
		return func t { return t + 7 }
