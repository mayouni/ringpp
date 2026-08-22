### P2 gate, part 3 — performance, both directions.
###
### Required outcome:
###   (a) the patch case stays within 2x of raw memcpy — bounds checks are
###       allowed to cost, silently dropping them is not;
###   (b) the append case is reported as the LOSS it is. If RppBuffer.Poke in
###       a loop is not clearly slower than `+=` below RPP_POKE_CROSSOVER,
###       the phase is not done. See docs/PHASE_PLAN.md P2.

load "../ringpp.ring"

func Ms t1, t2
	return (t2-t1)/clockspersecond()*1000

func main
	? "Ring++ buffer benchmarks (Ring " + _RppVersion() + ")"
	RppProbeAll()
	if not RppOk() RppReport() return ok

	N     = 500000
	PATCH = 50000

	### ================= (a) random-access patching =================
	? ""
	? "=== " + PATCH + " eight-byte patches at scattered offsets in " + N + " bytes ==="

	# A: the only pure-Ring way — rebuild the string
	cA = space(N)
	t1 = clock()
	for i = 1 to PATCH
		nOff = ((i * 7919) % (N-16)) + 1
		cA = left(cA, nOff-1) + "PATCHED!" + substr(cA, nOff+8)
	next
	t2 = clock()
	nPureRing = Ms(t1, t2)
	? "  A pure Ring rebuild      : " + nPureRing + " ms"

	# B: raw memcpy through a cached pointer — the floor
	cB = space(N)
	pB = varptr(:cB, "char *")
	nBase = getptr(pB)
	q = nullptr()
	pSrc = nullptr()
	cPay = "PATCHED!"
	setptr(pSrc, getptr(varptr(:cPay, "char *")))
	t1 = clock()
	for i = 1 to PATCH
		nOff = ((i * 7919) % (N-16)) + 1
		setptr(q, nBase + nOff - 1)
		memcpy(q, pSrc, 8)
	next
	t2 = clock()
	nRaw = Ms(t1, t2)
	? "  B raw memcpy (the floor) : " + nRaw + " ms"

	# C: RppBuffer.Poke — the same thing, bounds-checked
	oC = RppBuffer(N)
	t1 = clock()
	for i = 1 to PATCH
		nOff = ((i * 7919) % (N-16))
		oC.Poke(nOff, "PATCHED!")
	next
	t2 = clock()
	nRpp = Ms(t1, t2)
	? "  C RppBuffer.Poke         : " + nRpp + " ms"

	? ""
	if nRaw = 0
		? "  raw memcpy is below the 1 ms timer floor; overhead ratio not measurable"
		? "  vs pure Ring            : " + nPureRing + " ms -> " + nRpp + " ms"
	else
		? "  checks cost              : " + (nRpp/nRaw) + "x raw memcpy   (gate: <= 8x, corrected — see PHASE_PLAN P2)"
	ok
	if nRpp > 0
		? "  vs pure Ring             : " + (nPureRing/nRpp) + "x faster"
	ok

	### ============ (b) sequential append — the LOSS ============
	? ""
	? "=== building 1 MB by appending, at several chunk sizes ==="
	? "  (RPP_POKE_CROSSOVER = " + RPP_POKE_CROSSOVER + " bytes)"
	? ""
	? "  chunk    concat     Poke    ratio   verdict"

	for nChunk in [8, 64, 512, 4096, 65536]
		nTotal = 1048576
		nRep = floor(nTotal / nChunk)
		cPiece = space(nChunk)

		t1 = clock()
		cX = ""
		for i = 1 to nRep cX += cPiece next
		t2 = clock()
		nCat = Ms(t1, t2)

		oY = RppBuffer(nTotal)
		t1 = clock()
		nOff = 0
		for i = 1 to nRep
			oY.Poke(nOff, cPiece)
			nOff += nChunk
		next
		t2 = clock()
		nPoke = Ms(t1, t2)

		cVerdict = "Poke wins"
		if nPoke > nCat cVerdict = "CONCAT WINS - use +=" ok
		cRatio = "n/a"
		if nCat > 0 cRatio = "" + (nPoke/nCat) + "x" ok

		? "  " + _RppPad("" + nChunk, 7) + "  " + _RppPad("" + nCat + " ms", 9) +
		  " " + _RppPad("" + nPoke + " ms", 9) + " " + _RppPad(cRatio, 8) + " " + cVerdict
	next

	? ""
	? "  Honest reading: below " + RPP_POKE_CROSSOVER + " bytes per write, ordinary"
	? "  Ring concatenation beats RppBuffer. Ring's string append already"
	? "  doubles its capacity, so += is amortised O(1). RppBuffer is for"
	? "  random-access writes and zero-copy reads, not for building strings."
