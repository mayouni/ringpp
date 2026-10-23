# `not` and `!` bind LOOSER than every comparison and arithmetic operator and
# TIGHTER than `and` and `or`: `not a = b` is `not (a = b)`, `not a + b` is
# `not (a + b)`. The grammar's tree binds a `not` like a unary minus, tighter
# than every binary operator, so rnxc compiled `(not a) = b` and answered 0
# where Ring answers 1 -- a silent wrong answer. A `not` under parentheses is
# its own operand and keeps its meaning (the second block of rows).
# Measured on the oracle and on the official 1.27, which agree on every row.
# (The right operand of a tighter operator -- `a = not b`, `a + not b` -- is
# Ring's error C28, so no row has it.)

a = 0
b = 5
c = 2
s = "x"
aL = [a, b]

# ---- a `not` that leads a chain
put "not a = b                => "
? not a = b
put "not a + b                => "
? not a + b
put "not a < b                => "
? not a < b
put "not a * b                => "
? not a * b
put "!a = b                   => "
? !a = b
put "1 and not a = b          => "
? 1 and not a = b
put "not a and b              => "
? not a and b
put "not a or b               => "
? not a or b
put "not a = b + 1            => "
? not a = b + 1
put "not a + b = 5            => "
? not a + b = 5
put "not a * b + c            => "
? not a * b + c
put "not a - b * c            => "
? not a - b * c
put "not a < b * c            => "
? not a < b * c
put "not a % c                => "
? not a % c
put "not a | b                => "
? not a | b
put "not a << c               => "
? not a << c
put "not a != b               => "
? not a != b
put "not a >= b               => "
? not a >= b
put "not b <= c               => "
? not b <= c
put "not a != b = 1           => "
? not a != b = 1
put "not a < b and c          => "
? not a < b and c
put "not a = b or c           => "
? not a = b or c
put "not b = b and not a = b  => "
? not b = b and not a = b
put "a = b or not a = b       => "
? a = b or not a = b
put "not a + b and c          => "
? not a + b and c
put "c and not a + b          => "
? c and not a + b
put "1 and 1 and not a = b    => "
? 1 and 1 and not a = b
put "not len('ab') = c        => "
? not len("ab") = c
put "not (a + b) = c          => "
? not (a + b) = c
put "not aL[2] = b            => "
? not aL[2] = b
put "not s = 'x'              => "
? not s = 'x'
put "not s = 'y'              => "
? not s = 'y'

# ---- parenthesized: kept
put "(not a) = b              => "
? (not a) = b
put "a = (not b)              => "
? a = (not b)
put "(not a) + b              => "
? (not a) + b
put "(not a) < b              => "
? (not a) < b
put "a + (not b)              => "
? a + (not b)
put "(not a) * b              => "
? (not a) * b
put "(!a) = b                 => "
? (!a) = b
put "not (a = b)              => "
? not (a = b)
put "not (a + b)              => "
? not (a + b)
put "(not a = b)              => "
? (not a = b)
put "(not a) = (not b)        => "
? (not a) = (not b)
put "((not a)) = b            => "
? ((not a)) = b
put "a < b and not a          => "
? a < b and not a
put "not (a) = b              => "
? not (a) = b
put "not (a) + b              => "
? not (a) + b

# ---- in a condition, a loop, a return and a call
if not a = b
	? "if not a = b: taken"
else
	? "if not a = b: not taken"
ok
if (not a) = b
	? "if (not a) = b: taken"
else
	? "if (not a) = b: not taken"
ok
if not a + b
	? "if not a + b: taken"
else
	? "if not a + b: not taken"
ok
if !a < b and c
	? "if !a < b and c: taken"
else
	? "if !a < b and c: not taken"
ok
if c and not a = b
	? "if c and not a = b: taken"
else
	? "if c and not a = b: not taken"
ok
n = 0
while not n = 3
	n++
end
? "while not n = 3 ended at " + n
n = 0
while not n * 2 = 6 and n < 9
	n++
end
? "while not n * 2 = 6 ended at " + n
? "Same(0, 5)   = " + Same(0, 5)
? "Less(0, 5)   = " + Less(0, 5)
? "Sum(0, 5)    = " + Sum(0, 5)
? "Plain(0, 5)  = " + Plain(0, 5)
? "not f(a) = b = " + (not Id(a) = b)
? "not Id(a) + Id(b)"
? not Id(a) + Id(b)

# ---- the chain over several lines, with comments among its operands and after it, and a string that looks like the rest
? "Multi(b)    = " + Multi("b")
? "Multi(z)    = " + Multi("z")
? "Multi(5)    = " + Multi(5)
? "Short(0)    = " + Short(0)
? "Short(9)    = " + Short(9)
put "not a = b # tail         => "
? not a = b # a comment after the chain
x = not a + b # and after an assignment
? "x = not a + b # c          => " + x
if not a < b # a comment after a condition
	? "if not a < b # c: taken"
else
	? "if not a < b # c: not taken"
ok
put "not s = ')(= )'          => "
? not s = ')(= )'
put "not len('a#b') = c       => "
? not len('a#b') = c

func Multi(pcX)
	if NOT ( isString(pcX) and
	   	 find([ "a", "b",

			# a comment among the operands
			"c" ], pcX) ) > 0
		return "raised"
	ok
	return "fine"

func Short(n)
	if NOT n > 1 # the shape of stzStringFunc.ring:1769
		return "short"
	ok
	return "long"

func Same(x, y)
	return not x = y

func Less(x, y)
	return !x < y

func Sum(x, y)
	return not x + y

func Plain(x, y)
	return (not x) = y

func Id(x)
	return x
