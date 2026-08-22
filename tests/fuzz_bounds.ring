### P2 gate, part 2 — the safety fuzz.
###
### 100,000 random (offset, length) pairs against buffers of random sizes,
### most of them illegal. Required: ZERO crashes, and every illegal pair
### raising a catchable "Rpp:" error carrying offset, length and capacity.
###
### This is the gate DESIGN.md R3 lives or dies on. An over-read returns
### adjacent heap silently and an over-write kills the process with no
### message, so "it didn't crash" is the whole point — a pass here is the
### only evidence that the checks actually run before the primitive does.

load "../ringpp.ring"

### deterministic LCG, so a failure is reproducible
nSeed = 20260812

func NextRand nMax
	nSeed = (nSeed * 1103515245 + 12345) % 2147483648
	return floor((nSeed / 2147483648) * nMax)

func main
	nIters = 100000
	? "Ring++ bounds fuzz — " + nIters + " random accesses"

	RppProbeAll()
	if not RppOk()
		RppReport()
		? "ABORT: probe failed"
		return
	ok

	### Show the message shape FIRST. Catching many raises grows the VM stack
	### (RING_VM_STACK_SIZE is 1004 and a caught raise consumes a slot), so a
	### try/catch placed after the main loop can die silently. See FINDINGS F-16.
	try
		oX = RppBuffer(16)
		oX.Peek(12, 99)
	catch
		? "  sample message: " + trim(cCatchError)
		? ""
	done

	nLegal    = 0
	nRaised   = 0
	nBadRaise = 0     # raised, but not one of ours
	nSilent   = 0     # illegal, yet accepted -- a hole in the guard
	nWrongVal = 0     # legal, but the round trip did not match

	aSizes = [1, 7, 8, 48, 49, 256, 257, 512, 513, 4096]
	aBufs = []
	for nSz in aSizes
		aBufs + RppBuffer(nSz)
	next

	t1 = clock()
	for i = 1 to nIters
		nIdx  = NextRand(len(aSizes)) + 1
		oB    = aBufs[nIdx]
		nCap  = oB.Capacity()

		# offsets and lengths deliberately reach past the end, and go negative
		nOff = NextRand(nCap * 2) - floor(nCap / 4)
		nLen = NextRand(16) - 3

		bLegal = (nOff >= 0 and nLen >= 0 and nOff + nLen <= nCap)

		### ---- read ----
		try
			cGot = oB.Peek(nOff, nLen)
			if bLegal
				nLegal++
				if len(cGot) != nLen nWrongVal++ ok
			else
				nSilent++
			ok
		catch
			if bLegal
				nBadRaise++
			else
				nRaised++
				if substr(cCatchError, "Rpp:") = 0 nBadRaise++ ok
			ok
		done

		### ---- write, with a payload that starts with a zero byte ----
		# A zero-length write is legal at any in-range offset, whatever nLen
		# was: Poke() returns early. The payload's length is what matters.
		cPay = left(double2bytes(i * 0.5), max([0, nLen]))
		bLegalW = (nOff >= 0 and nOff + len(cPay) <= nCap)
		try
			oB.Poke(nOff, cPay)
			if not bLegalW nSilent++ ok
		catch
			if bLegalW
				nBadRaise++
			else
				nRaised++
			ok
		done
	next
	t2 = clock()

	? ""
	? "  legal reads that returned the right length : " + nLegal
	? "  illegal accesses correctly raised          : " + nRaised
	? "  illegal accesses SILENTLY ACCEPTED         : " + nSilent
	? "  raised when it should not have (or wrong)  : " + nBadRaise
	? "  legal reads with the wrong value           : " + nWrongVal
	? "  elapsed                                    : " + ((t2-t1)/clockspersecond()*1000) + " ms"
	? ""
	if nSilent = 0 and nBadRaise = 0 and nWrongVal = 0
		? "  GATE PASSED — 0 crashes, 0 silent holes, every error catchable"
	else
		? "  GATE FAILED"
	ok

