### The differential gate — Ring++ against a plain-Ring model of itself.
###
### Every other gate asks whether Ring++ raises when it should and returns the
### right LENGTH. None of them asks the question that matters most: after a
### long sequence of operations, are the BYTES the same as the obvious
### pure-Ring code would have produced?
###
### So this file keeps two representations of the same data side by side --
### an RppBuffer, and a plain Ring string rebuilt with left()/right() the slow
### way -- applies the same random operation to both, and compares the whole
### buffer after every single one. A divergence is a real bug in one of them,
### and the seed makes it reproducible.
###
### The payloads are chosen to be nasty on purpose: a leading zero byte (F-14
### kills the process on Ring <= 1.27 if Poke routes it wrong), the literal
### "NULL" (the same strcmp confusion), 0xFF runs, and writes that land
### exactly on the first and last legal offset.

load "../ringpp.ring"

nSeed = 20260825

func NextRand nMax
	nSeed = (nSeed * 1103515245 + 12345) % 2147483648
	if nMax <= 0 return 0 ok
	return floor((nSeed / 2147483648) * nMax)

### ---- the model: how a Ring programmer would do it, with no Ring++ ----

# Overwrite nOff..nOff+len(cData) in place, keeping the total length fixed.
# This is exactly RppBuffer.Poke's contract, written the plain way.
func ModelPoke cModel, nOff, cData
	nL = len(cData)
	if nL = 0 return cModel ok
	cLeft = ""
	if nOff > 0 cLeft = left(cModel, nOff) ok
	nAfter = len(cModel) - nOff - nL
	cRight = ""
	if nAfter > 0 cRight = right(cModel, nAfter) ok
	return cLeft + cData + cRight

# A fresh RppBuffer is space(n) -- 0x20, not zeros. The model must agree.
func ModelNew nBytes
	return copy(" ", nBytes)

func ModelGrow cModel, nNew
	return cModel + copy(" ", nNew - len(cModel))

### ---- the payload zoo ----

func PayloadFor nKind, nLen, i
	if nLen <= 0 return "" ok
	switch nKind
	on 0                                    # ordinary text
		return left(copy("abcdefgh", nLen), nLen)
	on 1                                    # leading zero byte -- F-14
		return left(RPP_NUL_BYTE + copy("Z", nLen), nLen)
	on 2                                    # the literal "NULL"
		if nLen >= 4 return "NULL" ok
		return left("NULL", nLen)
	on 3                                    # high bytes
		return left(copy(char(255), nLen), nLen)
	on 4                                    # packed double, arbitrary bytes
		return left(double2bytes(i * 0.5), nLen)
	on 5                                    # all zeros
		return copy(RPP_NUL_BYTE, nLen)
	other
		return left(copy("0123456789", nLen), nLen)
	off

### The shapes that killed the process, kept as named cases.
###
### The fuzz below found F-31 by luck: it had to draw a "NULL" payload at
### offset 0, then a zero byte at offset 4, then reach a Grow. Luck is not a
### regression test, so every shape that has ever crashed is asserted here by
### name, deterministically, before any random op runs.
func RegressionShapes
	nBad = 0

	# F-31 -- the C view of the source is "NULL" though the Ring length is 16.
	# Before the fix this killed the process outright, with no message.
	oB = RppBuffer(16)
	oB.Poke(0, "NULL")
	oB.Poke(4, RPP_NUL_BYTE)
	oB.Grow(33)
	if oB.Peek(0, 4) != "NULL" nBad++ ? "  FAIL: F-31 NULL<0> then Grow" ok

	# the same shape written in one call rather than assembled
	oC = RppBuffer(32)
	oC.Poke(0, "NULL" + RPP_NUL_BYTE + copy("x", 27))
	if oC.Peek(0, 4) != "NULL" nBad++ ? "  FAIL: F-31 single-call NULL<0>" ok
	if oC.Peek(5, 3) != "xxx" nBad++ ? "  FAIL: F-31 tail after NULL<0>" ok

	# "NULL" followed by something else must still take the fast path safely
	oD = RppBuffer(16)
	oD.Poke(0, "NULLx" + copy("y", 11))
	if oD.Peek(0, 5) != "NULLx" nBad++ ? "  FAIL: NULL followed by non-zero" ok

	# F-14 -- the literal four-byte NULL, and a leading zero byte
	oE = RppBuffer(8)
	oE.Poke(0, "NULL")
	if oE.Peek(0, 4) != "NULL" nBad++ ? "  FAIL: literal 4-byte NULL" ok
	oE.Poke(4, RPP_NUL_BYTE + "abc")
	if ascii(oE.Peek(4, 1)) != 0 nBad++ ? "  FAIL: leading zero byte" ok

	# a buffer that is nothing but zeros, grown
	oF = RppBuffer(64)
	oF.Fill(0, 64, 0)
	oF.Grow(129)
	if ascii(oF.Peek(0, 1)) != 0 nBad++ ? "  FAIL: all-zero buffer then Grow" ok

	# Grow must preserve every byte, including a zero in the middle
	oG = RppBuffer(8)
	oG.Poke(0, "ab" + RPP_NUL_BYTE + "cdefg")
	cBefore = oG.Peek(0, 8)
	oG.Grow(17)
	if oG.Peek(0, 8) != cBefore nBad++ ? "  FAIL: Grow changed the old bytes" ok

	return nBad

func main
	? "Ring++ differential gate — Ring++ against a plain-Ring model"
	? ""

	RppProbeAll()
	if not RppOk()
		RppReport()
		? "ABORT: probe failed"
		return
	ok

	### Named shapes first: a crash here is a regression, not a discovery.
	nShapeBad = RegressionShapes()
	if nShapeBad = 0
		? "  named regression shapes            : all pass"
	else
		? "  named regression shapes            : " + nShapeBad + " FAILED"
	ok

	nIters = 20000
	aSizes = [1, 2, 7, 8, 15, 16, 63, 64, 511, 512, 513, 4096]

	nOps      = 0
	nMismatch = 0
	nSkipped  = 0
	aByKind   = [0, 0, 0, 0, 0, 0, 0]

	cFirstFail = ""

	t1 = clock()

	for nSz in aSizes
		oB = RppBuffer(nSz)
		cM = ModelNew(nSz)

		# the buffer must start as the model does, before anything is written
		if oB.Str() != cM
			nMismatch++
			cFirstFail = "fresh buffer of " + nSz + " differs from space(" + nSz + ")"
			exit
		ok

		nPer = floor(nIters / len(aSizes))
		for i = 1 to nPer
			nCap = oB.Capacity()

			### choose a legal write: offset anywhere, length that fits
			nOff = NextRand(nCap)
			nMaxLen = nCap - nOff
			nLen = NextRand(nMaxLen + 1)
			nKind = NextRand(7)

			cPay = PayloadFor(nKind, nLen, i)
			# PayloadFor can return short for "NULL" on tiny nLen -- re-derive
			nLen = len(cPay)
			if nOff + nLen > nCap
				nSkipped++
				loop
			ok

			aByKind[nKind + 1] = aByKind[nKind + 1] + 1

			### apply to both
			oB.Poke(nOff, cPay)
			cM = ModelPoke(cM, nOff, cPay)
			nOps++

			### compare EVERY time -- a divergence that heals is still a bug
			if oB.Str() != cM
				nMismatch++
				cFirstFail = "Poke(off=" + nOff + ", len=" + nLen +
				             ", kind=" + nKind + ") on cap " + nCap
				exit
			ok

			### every 7th op, exercise a read path against the model too
			if i % 7 = 0
				nRo = NextRand(nCap)
				nRl = NextRand(nCap - nRo + 1)
				cGot = oB.Peek(nRo, nRl)
				cWant = ""
				if nRl > 0
					cWant = left(right(cM, len(cM) - nRo), nRl)
				ok
				if cGot != cWant
					nMismatch++
					cFirstFail = "Peek(" + nRo + ", " + nRl + ") on cap " + nCap
					exit
				ok

				### and a view over the same span -- it must agree with Peek
				oV = oB.View(nRo, nRl)
				if oV.Str() != cWant
					nMismatch++
					cFirstFail = "View(" + nRo + ", " + nRl + ").Str() on cap " + nCap
					exit
				ok
			ok
		next

		if nMismatch > 0 exit ok

		### ---- Grow, then confirm the old bytes survived exactly ----
		if nSz <= 512
			nNew = nSz * 2 + 1
			oB.Grow(nNew)
			cM = ModelGrow(cM, nNew)
			if oB.Str() != cM
				nMismatch++
				cFirstFail = "Grow(" + nSz + " -> " + nNew + ") lost or changed bytes"
				exit
			ok
			nOps++
		ok
	next

	t2 = clock()

	? "  operations compared byte-for-byte : " + nOps
	? "  payload kinds exercised           : text=" + aByKind[1] +
	  " nul-lead=" + aByKind[2] + " NULL=" + aByKind[3] +
	  " 0xFF=" + aByKind[4] + " double=" + aByKind[5] +
	  " zeros=" + aByKind[6] + " digits=" + aByKind[7]
	? "  skipped (payload did not fit)     : " + nSkipped
	? "  elapsed                           : " +
	  ((t2 - t1) / clockspersecond() * 1000) + " ms"
	? ""

	if nMismatch = 0 and nShapeBad = 0
		? "  GATE PASSED — Ring++ and plain Ring produced identical bytes throughout"
	else
		? "  GATE FAILED — first divergence:"
		? "    " + cFirstFail
	ok
