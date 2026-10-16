# A numeric loop's variable that the function ALSO assigns a value of another
# kind is a reference, and stays one. The compiler forced `int` on it while
# compiling the loop, so every read compiled after the loop was an unboxed,
# uncounted copy of whatever the register held -- dropped silently until an
# integer store began releasing what it overwrites (F-118's leak fix), and
# then released: a string still held elsewhere was freed, and three Softanza
# graphics tests died at a frame sweep. stzMathDiagram._MintShape is the
# shape: `for _v_ = 1 to _nV_`, then `_v_ = This._Prop(...)`, then
# `isNumber(_v_)` and `isString(_v_)` in a loop. 2026-10-14.

aKept = []
for k = 1 to 300
	aKept + Mint(k)
next
? "1 kept " + len(aKept) + ", first " + aKept[1] + ", last " + aKept[300]
? "2 " + Twice()

func Mint n
	for v = 1 to 3
		x = v
	next
	s = ""
	for i = 1 to 4
		v = Prop(i, n)
		if isNumber(v)
			s += "n"
		but isString(v) and len(v) > 0
			s += v
		ok
		m = i * 2
	next
	return s

func Prop i, n
	if i % 2 = 0 return i ok
	return "p" + n

func Twice
	t = ""
	for w = 1 to 2
		t += w
	next
	w = "word"
	return t + " " + w + " " + len(w)
