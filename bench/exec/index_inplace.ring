# A local index is read IN PLACE now (2026-10-15): a subscript's index register is the local's own, where it was
# copied into a temporary first. These rows pin what must not move with it -- a right-hand side that changes the
# index before `vset` reads it (Ring reads the index FIRST: `aL[i] = i++` writes aL[1]), an index that is also the
# destination, nested and compound forms, a string key. Inside a function, because at the top level a bare name is
# a global and takes the old path. Every row was taken from the oracle first; rows 3, 4 and 6 fail on a build that
# reads the index in place whatever the right-hand side does.

Rows()
? "r14 " + F(1, 3)

func Rows
	aL = [10, 20, 30, 40]
	i = 2
	x = aL[i]
	? "r1 " + x

	# the destination is the index itself
	i = 3
	i = aL[i]
	? "r2 " + i

	# the right-hand side moves the index: which element is written?
	aL = [1, 2, 3, 4]
	i = 1
	aL[i] = i++
	? "r3 " + aL[1] + " " + aL[2] + " " + i

	aL = [1, 2, 3, 4]
	i = 1
	aL[i] = eval("i = 3 return 7")
	? "r4 " + aL[1] + " " + aL[3] + " " + i

	# compound element, with a local on the right
	aL = [1, 2, 3, 4]
	i = 2
	n = 5
	aL[i] += n
	? "r5 " + aL[2]

	aL = [1, 2, 3, 4]
	i = 2
	aL[i] += i++
	? "r6 " + aL[2] + " " + aL[3] + " " + i

	# nested, written and read
	aB = [[1, 2], [3, 4]]
	i = 2  j = 1
	aB[i][j] = 99
	? "r7 " + aB[2][1] + " " + aB[i][j]
	aB[i][j] += j
	? "r8 " + aB[2][1]
	aB[i][j]++
	? "r9 " + aB[2][1]

	# a string key in a local
	aH = [:a = 1, :b = 2]
	k = "b"
	? "r10 " + aH[k]
	aH[k] = 22
	? "r11 " + aH[:b]

	# a compound with a local on the right, an integer and a string
	n = 3  m = 4
	n += m
	? "r12 " + n
	s = "ab"
	s += s
	? "r13 " + s

func F(p, q)
	aL = [5, 6, 7]
	return aL[p] + aL[q]
