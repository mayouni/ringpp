# What RppStr() costs, and what folding it away buys.
#
# Four arms, all producing the SAME string, differing only in how it is
# built. Minima over repetitions, Ring 1.27.
#
#   1. a plain literal              -- the floor. No escapes needed.
#   2. hand-written concatenation   -- what a Ring author writes today, and
#                                      exactly what `ringpp expand` folds
#                                      RppStr() into.
#   3. RppStr() with escapes        -- the portable form, decoded per call.
#   4. RppStr() with none           -- the early-out path, for a string
#                                      that has no backslash in it at all.
#
# The comparison that matters is 3 against 2: that gap is what the fold
# removes, and it is paid on EVERY evaluation, so it lands in a loop.

load "../rpp/str.ring"

func Main()
	nReps = 3
	nIter = 100000

	cWant = "He said " + char(34) + "5" + char(34) + " and left"

	nBestLit  = 999999
	nBestCat  = 999999
	nBestEsc  = 999999
	nBestPlain = 999999
	nBestUni   = 999999

	# The codepoint arm builds its own expected value, because the point of
	# \u is that its bytes are indistinguishable from a pasted character.
	cWantUni = "He said " + char(0xE4) + char(0xB8) + char(0xAD) + "5" +
		   char(0xE4) + char(0xB8) + char(0xAD) + " and left"

	for r = 1 to nReps

		t = clock()
		for i = 1 to nIter
			c = 'He said "5" and left'
		next
		n = Ms(t)
		if n < nBestLit nBestLit = n ok
		Assert(c, cWant, "literal")

		t = clock()
		for i = 1 to nIter
			c = "He said " + char(34) + "5" + char(34) + " and left"
		next
		n = Ms(t)
		if n < nBestCat nBestCat = n ok
		Assert(c, cWant, "concatenation")

		t = clock()
		for i = 1 to nIter
			c = RppStr("He said \q5\q and left")
		next
		n = Ms(t)
		if n < nBestEsc nBestEsc = n ok
		Assert(c, cWant, "RppStr with escapes")

		t = clock()
		for i = 1 to nIter
			c = RppStr("He said 5 and left")
		next
		n = Ms(t)
		if n < nBestPlain nBestPlain = n ok

		# 5. two CODEPOINT escapes. The same shape as arm 3, but each one is
		#    parsed as hex and then encoded to UTF-8, so it is the dearest.
		t = clock()
		for i = 1 to nIter
			c = RppStr("He said \u4E2D5\u4E2D and left")
		next
		n = Ms(t)
		if n < nBestUni nBestUni = n ok
		Assert(c, cWantUni, "RppStr with codepoints")

	next

	? "" + nIter + " evaluations, minimum of " + nReps + ":"
	? ""
	? "   1  plain literal                " + Fmt(nBestLit)
	? "   2  hand-written concatenation   " + Fmt(nBestCat) + "   <- what expand folds to"
	? "   3  RppStr(), with escapes       " + Fmt(nBestEsc)
	? "   4  RppStr(), nothing to decode  " + Fmt(nBestPlain) + "   <- early out"
	? "   5  RppStr(), two \u escapes     " + Fmt(nBestUni) + "   <- a codepoint costs most"
	? ""
	? "   per call, RppStr with escapes over the folded form: " +
	  Us(nBestEsc - nBestCat)
	? "   per call, the early-out over a plain literal:        " +
	  Us(nBestPlain - nBestLit)
	? ""
	? "WHERE THIS LOSES: arm 3 against arm 2. RppStr() decodes on every"
	? "evaluation, so a literal inside a hot loop pays the scan every pass"
	? "-- and a string built once at start-up pays it once and never again."
	? "That is the whole case for the fold, and the whole case against"
	? "reaching for RppStr() where a plain literal already says it."

func Ms(t)
	return (clock() - t) / clocksPerSecond() * 1000

func Fmt(n)
	if n < 1 return "below the 1 ms timer floor" ok
	return "" + floor(n) + " ms"

# ms over 100,000 calls -> us per call. This divided by 1,000,000 where it
# needed 1,000 and printed every per-call figure a THOUSAND times too large
# -- 8080 us for what is 8.08. Caught by reading the output instead of the
# code, which is the only way that kind of error is ever caught.
func Us(nMs)
	return "" + (floor(nMs / 100000 * 1000 * 100) / 100) + " us"

func Assert(cGot, cWant, cArm)
	if cGot != cWant or len(cGot) != len(cWant)
		? "MISMATCH in " + cArm + " -- the arms are not comparable"
		shutdown()
	ok
