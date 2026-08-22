### P3 gate — RppIndexed, RppSandbox, RppSyntaxOk, RppTokens, RppAdvise.

load "../ringpp.ring"

nPass = 0
nFail = 0

func Ms t1,t2  return (t2-t1)/clockspersecond()*1000

func Check cLabel, bOk
	if bOk
		nPass++
	else
		nFail++
		? "  FAIL " + cLabel
	ok

func Shuffled n, nReads
	a = list(nReads)
	nS = 12345
	for i = 1 to nReads
		nS = (nS * 16807) % 2147483647
		a[i] = floor((nS / 2147483647) * n) + 1
	next
	return a

func main
	? "Ring++ idioms tests"
	RppProbeAll()
	if not RppOk()
		RppReport()
		? "ABORT: probe failed"
		return
	ok

	### ---- RppIndexed refuses on a small list, and says why ----
	aSmall = []
	for i = 1 to 40 aSmall + i next
	oS = RppIndexed(aSmall)
	Check("refuses a 40-item list", oS.Applied() = FALSE)
	Check("and explains why", substr(oS.Why(), "below") > 0)

	### ---- and pays off on a big append-built one ----
	N = 60000
	R = 20000
	aIdx = Shuffled(N, R)
	aBig = []
	for i = 1 to N aBig + i next

	t1=clock() s=0 for i=1 to R s += aBig[aIdx[i]] next t2=clock()
	nBefore = Ms(t1,t2)

	oIdx = RppIndexed(aBig)
	Check("applies on a 60000-item list", oIdx.Applied() = TRUE)

	t1=clock() s2=0 for i=1 to R s2 += aBig[aIdx[i]] next t2=clock()
	nAfter = Ms(t1,t2)

	Check("same sum before and after", s = s2)
	nSpeed = 0
	if nAfter > 0 nSpeed = nBefore/nAfter ok
	? "  indexed read: " + nBefore + " ms -> " + nAfter + " ms  (" + nSpeed + "x)"

	### The gate is on the OUTCOME -- a permuted pass over 20000 rows is not
	### quadratic -- not on the mechanism that delivers it. A VM can reach it
	### two ways, and both are a pass:
	###
	###   * stock 1.27 walks the linked list on every random access, so the
	###     baseline is ~470 ms and RppIndexed buys the ~230x;
	###   * a VM patched to call ring_list_genarray_gc() on random access
	###     (RingScript's rlist.c does exactly this) is already fast, the
	###     baseline is ~4 ms, and there is nothing left for the idiom to buy.
	###
	### Asserting >= 20x unconditionally would report the *fixed* VM as the
	### failure. See FINDINGS F-23.
	if nBefore <= 50
		Check("permuted read is not quadratic (VM indexes natively)", nAfter <= 50)
		? "  note: this VM already generates the items array on random access;"
		? "        RppIndexed is a no-op here, by design."
	else
		Check("at least 20x on a permuted read", nSpeed >= 20)
	ok
	Check("Release reports a clean phase", oIdx.Release(aBig) = TRUE)

	### ---- a mutation during the phase is detected and advised ----
	RppAdviceClear()
	aM = []
	for i = 1 to 1000 aM + i next
	oM = RppIndexed(aM)
	aM + 9999
	Check("mutation makes Release return FALSE", oM.Release(aM) = FALSE)
	Check("and leaves advice", len(RPP_ADVICE) = 1)

	### ---- the caveat is stated, not hidden ----
	Check("caveat names sort()", substr(oIdx.Caveat(), "sort()") > 0)

	### ---- RppRows ----
	aR = RppRows(100, 5)
	Check("RppRows shape", len(aR) = 100 and len(aR[1]) = 5)

	### ---- RppSandbox: isolation, and a host that survives ----
	gHostVar = "HOST"
	oB = RppSandbox()
	oB.Quiet()
	oB.Run("gHostVar = 'SUB'")
	oB.Run("nTotal = 6 * 7")
	Check("host global untouched", gHostVar = "HOST")
	Check("Get folds the name (F-3 closed)", oB.Var("nTotal") = 42)
	Check("Has works", oB.Has("nTotal") = TRUE)
	Check("Has is false for a missing name", oB.Has("nope") = FALSE)

	### a runtime error inside must not kill us
	oB.Run("? 1/0")
	Check("host alive after a sub-state error", TRUE)
	oB.Run("nAfterErr = 5")
	Check("sandbox still usable after an error", oB.Var("nAfterErr") = 5)

	oB.Free()
	Check("Free closes it", oB.IsOpen() = FALSE)
	bRaised = FALSE
	try
		oB.Var("nTotal")
	catch
		bRaised = TRUE
	done
	Check("using a freed sandbox raises", bRaised)

	### ---- the scanner as a service ----
	Check("good code is ok",   RppSyntaxOk("x = 1 + 2") = TRUE)
	Check("bad code is not",   RppSyntaxOk("x = 'unterminated") = FALSE)
	aT = RppTokens("x = 1 + 2")
	Check("tokens come back", len(aT) >= 5)

	? ""
	? "  " + nPass + " passed, " + nFail + " failed"
	if nFail > 0 ? "  GATE FAILED" ok
	? ""
	RppAdvise()
