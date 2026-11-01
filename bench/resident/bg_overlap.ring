# RUNG 9, MEASURED: the program runs WHILE an admission compiles. A large admission is started in the background, and
# until it has compiled the program calls methods, runs eval -- which compiles code of its own, on this thread, against
# the VM's tables -- and builds strings, checking every answer; then it finishes the admission and calls what it brought.
# Prints how many rounds of that work ran while the other thread compiled, and how many answers were wrong (0). Not
# golden: the round count is a measurement.
oP = new Point { x = 3 y = 4 }
? "start: " + admitstart("admitcode", "big", Many(3000))
nRounds = 0
nBad = 0
while admitstate() = "compiling"
	nRounds++
	if eval("return oP.Len2() + " + nRounds) != 25 + nRounds nBad++ ok
	if oP.Len2() != 25 nBad++ ok
	cS = ""
	for i = 1 to 40
		cS += "ab"
	next
	if len(cS) != 80 nBad++ ok
end
? "finish: " + admitfinish() + ", Big3000() " + Big3000() + ", Big1() " + Big1()
? "rounds while it compiled: " + nRounds
? "wrong answers: " + nBad

func Many n
	cSrc = ""
	for i = 1 to n
		cSrc += "func Big" + i + nl + tab + "x = " + i + nl + tab + "y = x * 2 + 1" + nl + tab + "z = y - x" + nl + tab + "return x" + nl
	next
	return cSrc

class Point
	x = 0
	y = 0
	func Len2
		return x * x + y * y
