# `exit N` LEAVES N LOOPS AND `loop N` CONTINUES THE Nth, measured on both
# 1.27 builds: after `exit 2` the outer loop's variable keeps the value it
# had (row 1, i=1), `exit 3` leaves three, and `loop 2` abandons the inner
# loop and continues the outer one, skipping what follows the inner loop.
# Ring++ ignored the number until 2026-09-26: every `exit 2` left one loop.
# stzNatural's object scan is written with `exit 2`, so "Create a string
# with 'ring' called first Create a string with 'zig' ..." built 'zig' first.

s = ""
for i = 1 to 3
	for j = 1 to 3
		if j = 2
			exit 2
		ok
		s += "" + i + j + " "
	next
next
? "1 exit 2 from for-in-for: [" + s + "] i=" + i
s = ""
for i = 1 to 3
	for j = 1 to 3
		if j = 2
			exit 1
		ok
		s += "" + i + j + " "
	next
next
? "2 exit 1: [" + s + "]"
s = ""
for i = 1 to 3
	for j = 1 to 3
		if j = 2
			loop 2
		ok
		s += "" + i + j + " "
	next
	s += "|"
next
? "3 loop 2: [" + s + "]"
s = ""
i = 0
while i < 3
	i++
	for j = 1 to 3
		if j = 2 and i = 2
			exit 2
		ok
		s += "" + i + j + " "
	next
end
? "4 exit 2 from for-in-while: [" + s + "] i=" + i
s = ""
for a = 1 to 2
	for b = 1 to 2
		for c = 1 to 2
			if c = 2
				exit 3
			ok
			s += "" + a + b + c + " "
		next
	next
next
? "5 exit 3: [" + s + "]"
? "6 " + F()
s = ""
for x in [1, 2, 3]
	for y in ["a", "b"]
		if y = "b"
			exit 2
		ok
		s += "" + x + y + " "
	next
next
? "7 exit 2 from for-in over lists: [" + s + "]"

func F
	for i = 1 to 3
		for j = 1 to 3
			if j = 2
				exit 2
			ok
		next
	next
	return "exit 2 in a function, i=" + i + " j=" + j
