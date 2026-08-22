### P2 gate, part 1 — correctness.
### Round-trip every Poke/Peek pair at offset 0, at the last legal offset,
### across a Grow, and through a View of a View. Byte-compare against the
### equivalent pure-Ring construction.

load "../ringpp.ring"

nPass = 0
nFail = 0

func Check cLabel, vGot, vWant
	if vGot = vWant
		nPass++
	else
		nFail++
		? "  FAIL " + cLabel + "  got=[" + vGot + "] want=[" + vWant + "]"
	ok

func Raises cLabel, f
	bRaised = FALSE
	try
		call f()
	catch
		bRaised = TRUE
	done
	if bRaised nPass++ else nFail++ ? "  FAIL " + cLabel + " did not raise" ok

func main
	? "Ring++ buffer tests"

	### probe first — nothing below is meaningful if the assumptions moved
	RppProbeAll()
	if not RppOk()
		RppReport()
		? "ABORT: the probe says this Ring is not supported"
		return
	ok

	### ---- basic round trip ----
	oB = RppBuffer(64)
	Check("capacity", oB.Capacity(), 64)
	oB.Poke(0, "HELLO")
	Check("poke/peek at 0", oB.Peek(0, 5), "HELLO")
	oB.Poke(59, "WORLD")
	Check("poke/peek at last legal offset", oB.Peek(59, 5), "WORLD")
	Check("byte", oB.Byte(0), ascii("H"))

	### ---- packed numbers, including values with leading zero bytes ----
	oB.PokeInt32(8, 256)                      # 00010000 — the F-14 shape
	Check("int32 256", oB.PeekInt32(8), 256)
	oB.PokeInt32(12, 7)
	Check("int32 7", oB.PeekInt32(12), 7)
	oB.PokeDouble(16, 1.5)                    # 000000000000f83f
	Check("double 1.5", oB.PeekDouble(16), 1.5)
	oB.PokeDouble(24, -0.25)
	Check("double -0.25", oB.PeekDouble(24), -0.25)

	### ---- fill ----
	oF = RppBuffer(8)
	oF.Fill(0, 8, 65)
	Check("fill", oF.Str(), "AAAAAAAA")

	### ---- equivalence with the pure-Ring construction ----
	cWant = space(32)
	cWant = "ABCD" + substr(cWant, 5)
	oE = RppBuffer(32)
	oE.Poke(0, "ABCD")
	Check("equals pure-Ring build", oE.Str(), cWant)

	### ---- growth: the address moves, the contents do not ----
	oG = RppBuffer(16)
	oG.Poke(0, "0123456789ABCDEF")
	nOldAddr = oG.AddressUnchecked()
	oG.Grow(64)
	Check("grow keeps contents", oG.Peek(0, 16), "0123456789ABCDEF")
	Check("grow updates capacity", oG.Capacity(), 64)
	oG.Poke(16, "XYZ")
	Check("write past the old end", oG.Peek(16, 3), "XYZ")
	Check("contents survive the second write", oG.Peek(0, 19), "0123456789ABCDEFXYZ")

	### ---- views ----
	oV = RppBuffer(32)
	oV.Poke(0, "THE-QUICK-BROWN-FOX")
	v1 = oV.View(4, 5)
	Check("view", v1.Str(), "QUICK")
	v2 = v1.Sub(1, 3)
	Check("view of a view", v2.Str(), "UIC")
	Check("view byte", v1.Byte(0), ascii("Q"))
	Check("view keeps its owner", v1.Buffer().Capacity(), 32)

	### ---- a view sees writes made through the buffer ----
	oV.Poke(4, "SLOWX")
	Check("view is a window, not a copy", v1.Str(), "SLOWX")

	### ---- bounds: every illegal access raises, none crashes ----
	Raises("peek past the end",      func { oB.Peek(60, 10) })
	Raises("peek negative offset",   func { oB.Peek(-1, 4) })
	Raises("peek negative length",   func { oB.Peek(0, -4) })
	Raises("poke past the end",      func { oB.Poke(62, "ABCD") })
	Raises("view past the end",      func { oB.View(60, 10) })
	Raises("sub past the view",      func { v1.Sub(3, 9) })
	Raises("zero-size buffer",       func { RppBuffer(0) })
	Raises("grow must grow",         func { oG.Grow(8) })
	Raises("poke a non-string",      func { oB.Poke(0, 42) })

	### ---- empty writes are legal and do nothing ----
	oB.Poke(0, "")
	Check("empty poke is a no-op", oB.Peek(0, 5), "HELLO")

	### ---- from a string ----
	oS = RppBufferFromString("round-trip")
	Check("from string", oS.Str(), "round-trip")

	? ""
	? "  " + nPass + " passed, " + nFail + " failed"
	if nFail > 0
		? "  GATE FAILED"
	ok
