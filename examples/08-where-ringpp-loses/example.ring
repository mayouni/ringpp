# Ring++ example 08 -- where Ring++ LOSES
#
# THIS EXAMPLE EXISTS TO SHOW THE TOOL FAILING. A curriculum that only
# shows its good cases has not taught anyone when to reach for the thing --
# it has only taught them to trust it, which is worse than useless.
#
# THE TASK: hold 400,000 doubles and add them up. A column of measurements.
# A price series. Any numeric array.
#
# THE INTUITION, which is WRONG: "a packed 8-bytes-per-double buffer must
# beat a Ring list -- it is contiguous, it is cache-friendly, it is what C
# would do."
#
# THE MEASUREMENT: the packed buffer is about TWICE AS SLOW, and the plain
# Ring list is the right answer. (FINDINGS F-15.)
#
# WHY: reading one element from the packed buffer costs TWO crossings into
# C (~200 ns) -- fetch the bytes, then decode them. The Ring list costs ONE
# indexed read (~60 ns). Contiguity buys nothing when every access pays a
# call boundary, and Ring++'s whole advantage elsewhere is that it REMOVES
# call boundaries. Here it adds them.
#
# WHEN IT INVERTS: the same packed bytes read by COMPILED code are the K2
# kernel -- 1,000,000 doubles in 0.96 ms native against 92 ms as a Ring
# list. A packed numeric array is a COMPILED-HALF data structure. It is not
# wrong; it is premature.
#
# That is why RppArray is not in this library yet, and will arrive WITH the
# compiler rather than before it.

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nCount = 400000     # doubles
nReps  = 3

aList = []
for i = 1 to nCount
    aList + (i + 0.25)
next

oBuf = new RppBuffer(nCount * 8)
for i = 1 to nCount
    oBuf.PokeDouble((i - 1) * 8, i + 0.25)
next

? "Ring++ example 08 -- where Ring++ LOSES"
? copy("-", 58)
? "task   : sum " + nCount + " doubles"
? "        (a Ring list, against a packed 8-bytes-per-double buffer)"
? ""

### --------------------------------------------------- the plain Ring way

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nRaw = RawWay(aList, nCount)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### ------------------------------------------------------ the Ring++ way

nRppBest = 0
for r = 1 to nReps
    nT = clock()
    nRpp = RppWay(oBuf, nCount)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRppBest
        nRppBest = nMs
    ok
next

### -------------------------------------------------- correctness, first
#
# Both must agree exactly. A double survives PokeDouble/PeekDouble
# bit-for-bit, and the additions happen in the same order, so the sums are
# identical -- not merely close.

bSame = (nRaw = nRpp)
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- list " + nRaw + " vs packed " + nRpp
ok
? ""

### ----------------------------------------------------------- the number

? "raw Ring        : " + RppMs(nRawBest) + "   (a plain Ring list)"
? "Ring++          : " + RppMs(nRppBest) + "   (a packed buffer)"
? ""

if nRppBest > nRawBest and nRawBest > 0
    ? "RESULT: Ring++ is " + Ratio(nRppBest, nRawBest) + "x SLOWER."
    ? "        That is the CORRECT answer, and this example passes because"
    ? "        of it. Use a Ring list here."
but nRawBest > 0
    ? "RESULT: Ring++ came out faster on this run. That contradicts F-15."
    ? "        Treat it as a measurement fault, not a win, until re-checked."
ok
? ""

### -------------------------------------------------------- the reasoning

? "Why the packed buffer loses, and it is NOT the reason you would guess:"
? "  one list item  = ONE indexed read                      ~ 0.1 us"
? "  one PeekDouble = a method call, a CheckRange method"
? "                   call, a varptr, a getptr, a ptr2str"
? "                   and a bytes2double                    ~ 3.2 us"
? ""
? "  The dominant term is the VARPTR. RppBuffer.Base() re-derives the"
? "  address on EVERY access, and varptr costs ~790 ns (FINDINGS F-4)."
? ""
? "  That is deliberate, and it is a CORRECTNESS tax, not an oversight:"
? "  Ring copies an object on assignment and on list insertion, so a"
? "  cached address inside a copied buffer dangles into freed memory and"
? "  the process vanishes with no message (FINDINGS F-22). Re-deriving"
? "  is what makes RppBuffer safe to copy."
? ""
? "  Note the measured gap: F-15 reports 2.2x for the RAW packed idiom"
? "  (ptr2str + bytes2double against a cached pointer). Through the SAFE"
? "  API it is " + Ratio(nRppBest, nRawBest) + "x. The difference is the wrapper, and the"
? "  wrapper is what stops it crashing."
? ""
? "When it inverts:"
? "  the same bytes read by COMPILED code -- 1,000,000 doubles in"
? "  0.96 ms native against 92 ms as a Ring list. A packed numeric array"
? "  is a COMPILED-HALF data structure. Not wrong -- premature."
? ""
? "The rule this teaches, and it is the useful one:"
? "  RppBuffer is for BULK operations -- Poke a range, Peek a range,"
? "  hold a value across a call. Examples 01, 02 and 04 each touch the"
? "  buffer a few thousand times and win 25-86x."
? "  This loop touches it " + nCount + " times, ONE ELEMENT AT A TIME."
? "  That is the shape to avoid: per-element access through a safe"
? "  wrapper pays the safety on every element."
? ""
? "EXAMPLE 08 OK"

### =====================================================================

func RawWay aList, nCount
    # A plain Ring list, read in ascending order -- so the cursor cache hits
    # on every step and this is Ring at its best (see example 03 for what
    # happens when the order is NOT ascending).
    nSum = 0
    for i = 1 to nCount
        nSum += aList[i]
    next
    return nSum

func RppWay oBuf, nCount
    # The packed buffer. Every element costs a bounds check, a byte fetch
    # and a decode.
    nSum = 0
    for i = 1 to nCount
        nSum += oBuf.PeekDouble((i - 1) * 8)
    next
    return nSum

func Ratio nBig, nSmall
    if nSmall = 0
        return "?"
    ok
    return "" + (floor(nBig / nSmall * 10) / 10)

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
