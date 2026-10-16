# A container BORROWED for writing must survive an error caught after the
# borrow (2026-10-03). The compiler borrows a global (`ggetw`), an attribute
# (`gattrw`) or an element (`vgetw`) without taking a count, and ends the
# borrow with an instruction that stores without releasing -- on the normal
# path. An error between the two landed in the catch with the register still
# holding the container, and the catch's next write there released it: the
# global's list freed under it. ReleaseSafe said `integer overflow` in
# release; ReleaseFast printed the right answers until the memory was reused,
# which is what the junk below is for. Every row is the oracle's.
aL = [10, 20, 30]
try  del(aL, "a")  catch  ? "del: " + cCatchError  done
try  insert(aL, "x", 5)  catch  ? "insert: " + cCatchError  done
try  add(aL, Boom())  catch  ? "add: " + cCatchError  done
aJunk = []
for i = 1 to 200  aJunk + ("junk" + i)  next
? "aL after: " + len(aL) + " [" + aL[1] + ", " + aL[2] + ", " + aL[3] + "]"
for i = 1 to 100
	try  del(aL, "a")  catch  cE = "" + cCatchError  done
next
aJunk2 = []
for i = 1 to 200  aJunk2 + ("more" + i)  next
? "aL after 100 more: " + len(aL) + " [" + aL[1] + ", " + aL[3] + "]"
aN = MakeN()
try  aN[2][Boom()] = 9  catch  ? "element: " + cCatchError  done
aJunk3 = []
for i = 1 to 200  aJunk3 + ("third" + i)  next
? "aN after: " + len(aN) + " " + aN[2][1] + " " + aN[2][2]
o = new K
o.Run()
o.Run()
? "attribute after: " + len(o.@aM) + " " + o.@aM[1] + " " + o.@aM[3]

func MakeN
	return [[1, 2], [3, 4]]

func Boom
	raise("boom")

class K
	@aM = [1, 2, 3]

	func Run
		try  del(@aM, "a")  catch  ? "method del: " + cCatchError  done
		aJ = []
		for i = 1 to 200  aJ + ("m" + i)  next
		? "attribute inside: " + len(@aM) + " " + @aM[2]
