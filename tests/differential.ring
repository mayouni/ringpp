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

### ---- RppView, against the same plain-Ring model ----
###
### A view is the only other thing in the library holding a pointer into a
### buffer, and until now the only thing any gate asked of it was Str().
### Sub() -- a view of a view -- was tested nowhere at all, and a view held
### across Grow() is the exact shape F-22 describes: the owner reallocates
### underneath a window that is still alive.
func DifferentialViews
	nBad = 0

	cM = ""
	for i = 1 to 256
		cM += char((i * 7) % 251 + 1)      # no zero bytes, so left/right stay honest
	next
	oB = RppBufferFromString(cM)
	if oB.Str() != cM
		nBad++ ? "  FAIL: RppBufferFromString did not round-trip"
		return nBad
	ok

	### 1. every view of every span must equal the model's slice
	nSpans = 0
	for nOff = 0 to 250 step 5
		for nLen = 0 to 6
			if nOff + nLen > 256 loop ok
			oV = oB.View(nOff, nLen)
			cWant = ""
			if nLen > 0 cWant = left(right(cM, 256 - nOff), nLen) ok
			if oV.Str() != cWant
				nBad++ ? "  FAIL: View(" + nOff + "," + nLen + ").Str()"
				return nBad
			ok
			if oV.Size() != nLen   nBad++ ? "  FAIL: View.Size " + nOff ok
			if oV.Offset() != nOff nBad++ ? "  FAIL: View.Offset " + nOff ok
			nSpans++
		next
	next

	### 2. Sub() -- a view of a view. Offsets must COMPOSE, not restart.
	oOuter = oB.View(100, 60)
	for nSo = 0 to 50 step 7
		for nSl = 0 to 8
			if nSo + nSl > 60 loop ok
			oIn = oOuter.Sub(nSo, nSl)
			cWant = ""
			if nSl > 0 cWant = left(right(cM, 256 - (100 + nSo)), nSl) ok
			if oIn.Str() != cWant
				nBad++ ? "  FAIL: Sub(" + nSo + "," + nSl + ") did not compose"
				return nBad
			ok
			if oIn.Offset() != 100 + nSo
				nBad++ ? "  FAIL: Sub offset " + oIn.Offset() + " want " + (100 + nSo)
				return nBad
			ok
		next
	next

	### 3. a Sub of a Sub of a Sub still lands on the right byte
	oD = oB.View(0, 256).Sub(64, 128).Sub(16, 64).Sub(8, 8)
	if oD.Str() != left(right(cM, 256 - 88), 8)
		nBad++ ? "  FAIL: three-deep Sub chain"
	ok
	if oD.Offset() != 88 nBad++ ? "  FAIL: three-deep Sub offset = " + oD.Offset() ok

	### 4. the view is a WINDOW: a write through the buffer must show through it
	oW = oB.View(10, 4)
	oB.Poke(10, "WXYZ")
	if oW.Str() != "WXYZ"
		nBad++ ? "  FAIL: view did not see a write made through the buffer"
	ok
	# and through the sub-view of that window
	if oW.Sub(1, 2).Str() != "XY"
		nBad++ ? "  FAIL: sub-view did not see the write"
	ok

	### 5. Buffer() gets back to the owner, and it is the SAME bytes
	if oW.Buffer().Peek(10, 4) != "WXYZ"
		nBad++ ? "  FAIL: View.Buffer() is not the owning buffer"
	ok

	### 6. out-of-range Sub and Peek must RAISE, not return adjacent heap
	nRaised = 0
	try  oW.Sub(3, 5)   catch nRaised++ done      # 3+5 > 4
	try  oW.Sub(-1, 2)  catch nRaised++ done
	try  oW.Peek(0, 99) catch nRaised++ done
	try  oW.Peek(-1, 1) catch nRaised++ done
	if nRaised != 4
		nBad++ ? "  FAIL: only " + nRaised + " of 4 illegal view accesses raised"
	ok

	### 7. a view held ACROSS Grow -- the owner reallocates under a live window
	oG = RppBufferFromString("0123456789")
	oLive = oG.View(2, 4)
	cBefore = oLive.Str()
	oG.Grow(64)
	cAfter = oLive.Str()
	if cAfter != cBefore
		nBad++ ? "  FAIL: view across Grow read [" + cAfter + "] want [" + cBefore + "]"
	ok
	# and it must still be a window afterwards, not a snapshot
	oG.Poke(2, "abcd")
	if oLive.Str() != "abcd"
		nBad++ ? "  FAIL: view stopped tracking after Grow"
	ok

	? "  RppView differential                : " + nSpans +
	  " spans, Sub chains, window and Grow checks"
	return nBad

### ---- RppSandbox: the two traps F-3 names, and the ones nothing tested ----
###
### `ring_state_findvar` folds identifiers to lower case and reports ABSENCE
### as the NUMBER 0 -- indistinguishable from a variable that holds 0. Both
### traps are closed inside RppSandbox; nothing until now checked that they
### stayed closed, and SetVar had no coverage at all.
func DifferentialSandbox
	nBad = 0
	nChecks = 0

	oS = RppSandbox()

	### 1. a variable that genuinely HOLDS 0 must read back as 0, not as absent.
	### This is the exact F-3 confusion, and it is the one worth a gate.
	oS.Run("nZero = 0")
	bRaised = FALSE
	nGot = -1
	try
		nGot = oS.Var("nZero")
	catch
		bRaised = TRUE
	done
	if bRaised
		nBad++ ? "  FAIL: a variable holding 0 was reported as absent (F-3)"
	but nGot != 0
		nBad++ ? "  FAIL: nZero read back as " + nGot
	ok
	nChecks++

	### 2. an absent name must RAISE, not quietly return 0
	bRaised = FALSE
	try
		oS.Var("nNeverSet")
	catch
		bRaised = TRUE
	done
	if not bRaised nBad++ ? "  FAIL: an absent variable did not raise" ok
	nChecks++

	### 3. Has() must agree with Var() on both of those
	if not oS.Has("nZero")     nBad++ ? "  FAIL: Has() missed a live 0" ok
	if oS.Has("nNeverSet")     nBad++ ? "  FAIL: Has() invented a variable" ok
	nChecks++

	### 4. the case fold: Ring stores identifiers lower, the caller writes camel
	oS.Run("nTotalCount = 42")
	if oS.Var("nTotalCount") != 42 nBad++ ? "  FAIL: camelCase name not found" ok
	if oS.Var("ntotalcount") != 42 nBad++ ? "  FAIL: lower name not found" ok
	if oS.Var("NTOTALCOUNT") != 42 nBad++ ? "  FAIL: upper name not found" ok
	nChecks++

	### 5. SetVar -- never exercised by any gate before this one
	oS.SetVar("cGreeting", "hello")
	oS.Run("cEcho = cGreeting + ' world'")
	if oS.Var("cEcho") != "hello world"
		nBad++ ? "  FAIL: SetVar value did not reach the sandbox: [" + oS.Var("cEcho") + "]"
	ok
	oS.SetVar("nNum", 7)
	oS.Run("nDouble = nNum * 2")
	if oS.Var("nDouble") != 14 nBad++ ? "  FAIL: numeric SetVar round-trip" ok
	nChecks++

	### 6. containment: an error inside must NOT kill this process (F-13).
	### A RUNTIME error on purpose -- Quiet() suppresses those. Scanner errors
	### print regardless, which F-13 measured and example 07 records, so using
	### one here would make a passing gate look like a failing one.
	oS.Quiet()
	oS.Run("callSomethingThatDoesNotExist()")
	oS.Run("nAfterError = 99")
	if oS.Var("nAfterError") != 99
		nBad++ ? "  FAIL: sandbox unusable after an error inside it"
	ok
	nChecks++

	### 7. two sandboxes are isolated from each other, and from the host
	nHostOnly = 12345
	oT = RppSandbox()
	oT.Run("nIsolated = 1")
	if oS.Has("nIsolated")   nBad++ ? "  FAIL: state leaked between sandboxes" ok
	if oT.Has("nZero")       nBad++ ? "  FAIL: state leaked the other way" ok
	if oT.Has("nHostOnly")   nBad++ ? "  FAIL: the host's own variable was visible" ok
	nChecks++

	### 8. Free() twice is safe, and using a freed sandbox raises rather than crashes
	oT.Free()
	if oT.IsOpen() nBad++ ? "  FAIL: IsOpen() true after Free()" ok
	oT.Free()                                   # must not crash
	bRaised = FALSE
	try
		oT.Run("x = 1")
	catch
		bRaised = TRUE
	done
	if not bRaised nBad++ ? "  FAIL: Run() on a freed sandbox did not raise" ok
	nChecks++

	oS.Free()
	? "  RppSandbox differential             : " + nChecks +
	  " checks incl. the F-3 zero-versus-absent trap and SetVar"
	return nBad

### ---- RppIndexed: the phase must change the SPEED and nothing else ----
###
### `ringvm_genarray` is an accelerator, so the only correctness question is
### whether an indexed read ever differs from a plain one. Nothing compared
### them before. The other half is honesty: Release() reports whether the
### index survived, and Caveat() admits the one case it CANNOT see -- sort()
### and reverse() free the items array without changing len(). That admission
### is only worth having if it is true, so it is asserted here.
func DifferentialIndexed
	nBad = 0

	### 1. read equivalence: same list, same order of reads, indexed or not
	nN = 2000
	aPlain = list(nN)
	for i = 1 to nN aPlain[i] = "row-" + i next
	aSame = list(nN)
	for i = 1 to nN aSame[i] = "row-" + i next

	oIdx = RppIndexed(aSame)
	nDiff = 0
	nRead = 0
	for k = 1 to 4000
		nAt = ((k * 7919) % nN) + 1
		if aSame[nAt] != aPlain[nAt] nDiff++ ok
		nRead++
	next
	if nDiff > 0
		nBad++ ? "  FAIL: " + nDiff + " indexed reads differed from plain reads"
	ok
	if not oIdx.Applied()
		nBad++ ? "  FAIL: a 2000-item list declined the index: " + oIdx.Why()
	ok
	if not oIdx.Release(aSame)
		nBad++ ? "  FAIL: Release() reported the index invalid after reads only"
	ok

	### 2. below the floor it must DECLINE, and say so rather than pretend
	aTiny = list(8)
	for i = 1 to 8 aTiny[i] = i next
	oT = RppIndexed(aTiny)
	if oT.Applied()
		nBad++ ? "  FAIL: an 8-item list took the index (floor is " +
		         RPP_INDEX_MIN_SIZE + ")"
	ok
	if len(oT.Why()) = 0 nBad++ ? "  FAIL: Why() was empty on a declined phase" ok
	if oT.Release(aTiny)
		nBad++ ? "  FAIL: Release() claimed validity for a phase never applied"
	ok

	### 3. one append during the phase must be REPORTED, not hidden (F-9)
	aGrow = list(200)
	for i = 1 to 200 aGrow[i] = i next
	RppAdviceClear()
	oG = RppIndexed(aGrow)
	aGrow + 999                                  # the single add that frees the array
	if oG.Release(aGrow)
		nBad++ ? "  FAIL: Release() said valid after an append"
	ok
	if len(RPP_ADVICE) = 0
		nBad++ ? "  FAIL: an append during the phase produced no advice"
	ok

	### 4. the admission in Caveat() must be TRUE: sort() changes the items
	### array without changing len(), so Release() cannot detect it and must
	### not claim it can. This asserts the LIMIT, not a capability.
	aSort = list(300)
	for i = 1 to 300 aSort[i] = 301 - i next
	oS2 = RppIndexed(aSort)
	aSort = sort(aSort)
	bClaimed = oS2.Release(aSort)
	if not bClaimed
		nBad++ ? "  FAIL: Release() detected a sort -- Caveat() now overstates the limit"
	ok
	if len(oS2.Caveat()) = 0 nBad++ ? "  FAIL: Caveat() is empty" ok
	# and the sorted data must still be correct, whatever the index thinks
	if aSort[1] != 1 or aSort[300] != 300
		nBad++ ? "  FAIL: sort() produced wrong data under an open phase"
	ok

	### 5. RppRows -- the 2D idiom, and its refusal on bad dimensions
	aR = RppRows(4, 5)
	if len(aR) != 4 or len(aR[1]) != 5 nBad++ ? "  FAIL: RppRows dimensions" ok
	nRaised = 0
	try RppRows(0, 5)  catch nRaised++ done
	try RppRows(3, -1) catch nRaised++ done
	if nRaised != 2 nBad++ ? "  FAIL: RppRows accepted a bad dimension" ok

	? "  RppIndexed differential            : " + nRead +
	  " indexed-vs-plain reads, floor, append and the sort caveat"
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
	nShapeBad += DifferentialViews()
	nShapeBad += DifferentialSandbox()
	nShapeBad += DifferentialIndexed()
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
