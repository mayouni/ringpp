# A FUNCTION WITH NO `return` YIELDS NULL -- the empty STRING -- and Ring++
# handed back the NUMBER 0.
#
# Measured on 1.27 before a line changed, for a function and a method alike:
#
#     type STRING, isNull 1, len 0, `= ""` TRUE      on Ring
#     type NUMBER, isNull 0, len 1, `= ""` FALSE     on Ring++
#
# and the same for a BARE `return`, early branch returns included. Every
# function and method without an explicit return, across the whole estate,
# answered 0 -- silently -- and two narrated tests asserting "X() returns
# nothing" failed on it. The compiler's own comment said the opposite: "A
# function that runs off its end returns 0, as Ring's does."
#
# THE ROWS BELOW ARE AIMED AT THE TWO WAYS THE FIX COULD GO WRONG, not at
# the value alone:
#
#   rows 3-4  a function typed INTEGER by its `return n` that can ALSO fall
#             off its end. Falling off was not in the type table at all, so
#             after the value changed, `x = F(-1)` would have sat in an
#             unboxed register and `x + 1` would have run as integer
#             arithmetic on a string. These pin Ring's answer for exactly that.
#   row 5     a METHOD falling off its end, in a loop. r0 of a method is the
#             receiver, and loading the string there would have released
#             `this` once per call -- an over-release that surfaces only
#             after the count has been walked down, so the loop is the point.
#   row 6     a bare `return` inside a method, in the same loop.

? "-- 1. a function with no return --"
v = NoReturn()
? "  type " + type(v) + "  isNull " + isNull(v) + "  len " + len("" + v)
? "  = ''  " + (v = "")

? ""
? "-- 2. a bare return, and an early one in a branch --"
b = Bare()
? "  Bare()     " + type(b) + " " + isNull(b)
e = Early(1)
? "  Early(1)   " + type(e) + " " + isNull(e)
e2 = Early(2)
? "  Early(2)   " + type(e2) + " " + e2

? ""
? "-- 3. typed INTEGER by `return n`, and ALSO able to fall off --"
p = Pos(5)
? "  Pos(5)     " + type(p) + " " + p
q = Pos(-1)
? "  Pos(-1)    " + type(q) + " isNull " + isNull(q)

? ""
? "-- 4. and arithmetic on each, which is where a stale type would show --"
? "  Pos(5) + 1   = " + (Pos(5) + 1)
? "  Pos(-1) + 'x' = " + (Pos(-1) + "x")
nSum = 0
for i = -3 to 3
	r = Pos(i)
	if isNumber(r)
		nSum += r
	ok
next
? "  sum of the numeric ones = " + nSum

? ""
? "-- 5. a METHOD falling off its end, 20000 times --"
o = new K
nNull = 0
for i = 1 to 20000
	if isNull(o.Touch()) nNull++ ok
next
? "  all null: " + (nNull = 20000) + "   and o still answers: " + o.Count()

? ""
? "-- 6. a bare return in a method, 20000 times --"
nNull = 0
for i = 1 to 20000
	if isNull(o.Quit()) nNull++ ok
next
? "  all null: " + (nNull = 20000) + "   count now " + o.Count()

? ""
? "done"

func NoReturn
	x = 1

func Bare
	return

func Early n
	if n = 1
		return
	ok
	return 7

func Pos n
	if n > 0
		return n
	ok

class K
	nTouched = 0

	def Touch()
		nTouched++

	def Quit()
		nTouched++
		return

	def Count()
		return nTouched
