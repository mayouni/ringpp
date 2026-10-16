# `do <body> again <cond>` -- Ring's POST-test loop, and the only loop whose
# test is the LAST child rather than the first.
#
# It is not an exotic corner. RING'S OWN STANDARD LIBRARY uses it twice, in
# `Split()` (libraries/stdlib/stdlibcore.ring), and the estate loads
# stdlibcore on every program -- so that whole function was refused, and
# with it everything that calls it, for as long as this was missing.
#
# Four rows measured on 1.27 before any of it was written. The third and
# fourth are the ones that could not be guessed: a post-test loop could
# reasonably send `loop` either to the top of the body or to the re-test,
# and guessing would have been a silent wrong answer rather than a refusal.

? "-- 1. it repeats while the condition is TRUE, tested after the body --"
i = 0
do
	i++
	? "  i = " + i
again i < 3

? ""
? "-- 2. and the body runs at least ONCE, false at entry or not --"
j = 10
do
	j++
	? "  j = " + j
again j < 3

? ""
? "-- 3. `exit` leaves it --"
k = 0
do
	k++
	if k = 2
		exit
	ok
again k < 9
? "  k = " + k

? ""
? "-- 4. `loop` restarts the body (this row cannot tell: the test is true) --"
m = 0
n = 0
do
	m++
	if m = 2
		loop
	ok
	n++
	? "  body tail, m = " + m + " n = " + n
again m < 4
? "  after: m = " + m + " n = " + n

? ""
? "-- 4b. `loop` restarts the body WITHOUT the test (F-125) --"
# Row 4 above was read as `loop` jumping to the re-test, but its condition
# is still true at the `loop`, where both readings agree. Here it is false:
# the re-test would leave at x = 5, and Ring runs the body to x = 10.
x = 0
s = ""
g = 0
do
	g++
	if g > 20 exit ok
	x++
	if x < 10 loop ok
	s += " " + x
again x < 5
? "  g = " + g + ", printed:" + s

? ""
? "-- 5. nested, each with its own exit --"
cOut = ""
a = 0
do
	a++
	b = 0
	do
		b++
		cOut += "" + a + ":" + b + " "
	again b < 2
again a < 3
? "  " + cOut

? ""
? "done"
