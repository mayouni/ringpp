# Ring and Ring++ on a phone — algorithms, checked and timed.
#
#     ring algorithms.ring [scale]
#
# TWO KINDS OF LINE come out of this file, and they are read differently:
#
#   CHECK <name> <value>   a result that MUST be identical everywhere.
#                          The campaign runs this same file on x64 Windows
#                          and on arm64 Android and diffs these lines. A
#                          disagreement is an architecture bug, and it is
#                          why the checks are printed rather than compared
#                          against constants written here by hand: a
#                          constant I typed is a guess, agreement between
#                          two machines is evidence.
#
#   TIME <name> <ms>       minimum over repetitions, never a single run.
#                          These are EXPECTED to differ between machines.
#
# The first six algorithms are plain Ring with no Ring++ anywhere. That is
# deliberate: they measure the VM itself, so they can be put beside another
# language's VM on the same phone without the comparison being rigged.
#
# The rest are Ring/Ring++ pairs. Each asserts the two paths agree BEFORE
# any speed number is printed, so a false claim cannot reach the output.
#
# LAYOUT: every executable statement is above the first `func`. In Ring the
# main program ENDS at the first function definition — code written after
# one silently becomes part of it, and the program runs its header and
# stops with no error at all. Cost me one run to remember (F-21 is the same
# rule for classes).

load "../../ringpp.ring"

nScale = 1
if len(sysargv) >= 3
    nScale = number(sysargv[3])
    if nScale < 1 nScale = 1 ok
ok

nReps = 3          # report the minimum; a single run is noise

? "Ring / Ring++ algorithm suite"
? copy("=", 46)
? "scale : " + nScale
? ""
? "-- plain Ring: the VM on its own ------------------------"
? ""

### A1. sieve -------------------------------------------------------
nN = 300000 * nScale
nBest = -1
for r = 1 to nReps
    nT = clock() nV = Sieve(nN) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("sieve", nBest, nV)

### A2. matrix multiply ---------------------------------------------
nN = 80 * nScale
nBest = -1
for r = 1 to nReps
    nT = clock() nV = MatMul(nN) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("matmul", nBest, nV)

### A3. recursive fib -----------------------------------------------
nBest = -1
for r = 1 to nReps
    nT = clock() nV = Fib(25) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("fib", nBest, nV)

### A4. mergesort ---------------------------------------------------
nN = 8000 * nScale
aData = []
for i = 1 to nN aData + ((i * 7919) % 100003) next
nBest = -1
for r = 1 to nReps
    nT = clock() aS = MergeSort(aData) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
# Sortedness is asserted, not assumed: a checksum alone would accept a
# permutation that happened to hash the same.
for i = 2 to len(aS)
    if aS[i] < aS[i-1]
        raise("mergesort produced an unsorted list at " + i)
    ok
next
Report("mergesort", nBest, Sum32(aS))

### A5. binary search -----------------------------------------------
nBest = -1
for r = 1 to nReps
    nT = clock() nV = BinSearchAll(aS, 6000 * nScale) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("binsearch", nBest, nV)

### A5b. binary search through RppIndexed --------------------------
# F-42: Ring reaches a list element by walking from a cached cursor, so a
# random access costs O(distance) -- and binary search's first probe jumps
# half the list. On a Ring list the algorithm is O(n) per query while
# reading as O(log n). RppIndexed (ringvm_genarray) restores O(1) access;
# same searches, same hits, asserted equal.
oBs = RppIndexed(aS)
nBest = -1
for r = 1 to nReps
    nT = clock() nV2 = BinSearchAll(aS, 6000 * nScale) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
oBs.Release(aS)
if nV2 != nV
    raise("indexed binsearch disagrees with plain (" + nV2 + " vs " + nV + ")")
ok
? "TIME  binsearch-rpp " + Fmt(nBest)
TimerFloor("binsearch-rpp", nBest)

### A6. byte scan ---------------------------------------------------
cBig = ""
for i = 1 to 4000 * nScale cBig += "the quick brown fox " next

# A far larger string for the slice comparison. substr() copies the WHOLE
# string across the call boundary, so its cost tracks the buffer's size and
# not the slice's -- on an 80 KB string the effect is invisible, which is
# exactly how this trap survives review.
cHuge = ""
for i = 1 to 40000 * nScale cHuge += "the quick brown fox " next
nBest = -1
for r = 1 to nReps
    nT = clock() nV = ByteScan(cBig) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("bytescan", nBest, nV)

? ""
? "-- Ring vs Ring++: same answer, then the cost -----------"
? ""

### B1. patching a buffer in place ----------------------------------
nSize = 200000 * nScale
nPatch = 4000 * nScale
cPatch = "RING++!!"
nStep = floor(nSize / nPatch)

nBest = -1
for r = 1 to nReps
    nT = clock() cA = RawPatch(nSize, nPatch, nStep, cPatch) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRawMs = nBest

nBest = -1
for r = 1 to nReps
    nT = clock() cB = RppPatch(nSize, nPatch, nStep, cPatch) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRppMs = nBest

if cA != cB
    raise("patch: the two paths disagree — no speed number is printed")
ok
? "CHECK patch " + StrSum(cA)
? "TIME  patch-ring " + Fmt(nRawMs)
? "TIME  patch-rpp " + Fmt(nRppMs)
TimerFloor("patch-ring", nRawMs) TimerFloor("patch-rpp", nRppMs)

### B2. reading many small slices -----------------------------------
nSlices = 4000 * nScale
nLen = 10
oSrc = RppBufferFromString(cHuge)

nBest = -1
for r = 1 to nReps
    nT = clock() nA = RawSlices(cHuge, nSlices, nLen) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRawMs = nBest

nBest = -1
for r = 1 to nReps
    nT = clock() nB = RppSlices(oSrc, nSlices, nLen) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRppMs = nBest

# substr() is 1-based and Peek() is 0-based, so the two walk the same
# offsets only if that was written correctly. The assert is what proves it.
if nA != nB
    raise("slices: the two paths disagree (" + nA + " vs " + nB + ")")
ok
? "CHECK slices " + nA
? "TIME  slices-ring " + Fmt(nRawMs)
? "TIME  slices-rpp " + Fmt(nRppMs)
TimerFloor("slices-ring", nRawMs) TimerFloor("slices-rpp", nRppMs)

### B3. permuted reads over a list ----------------------------------
nItems = 1500 * nScale
nReads = 150000 * nScale
aBig = []
for i = 1 to nItems aBig + ((i * 31) % 977) next

nBest = -1
for r = 1 to nReps
    nT = clock() nA = RawReads(aBig, nReads) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRawMs = nBest

oIdx = RppIndexed(aBig)
nBest = -1
for r = 1 to nReps
    nT = clock() nB = RawReads(aBig, nReads) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nRppMs = nBest
cApplied = "" + oIdx.Applied()
oIdx.Release(aBig)

if nA != nB
    raise("reads: the two paths disagree")
ok
? "CHECK reads " + nA
? "TIME  reads-ring " + Fmt(nRawMs)
? "TIME  reads-rpp " + Fmt(nRppMs)
TimerFloor("reads-ring", nRawMs) TimerFloor("reads-rpp", nRppMs)
? "NOTE  reads-applied " + cApplied

### B4. the substr trap, priced on THIS machine ---------------------
# Not a Ring++ feature — a Ring mistake, measured here so the documentation
# can quote a number from the phone rather than from a desktop.
nLimit = 60000 * nScale
nBest = -1
for r = 1 to nReps
    nT = clock() nA = ByteScanSubstr(cBig, nLimit) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nSubMs = nBest

nBest = -1
for r = 1 to nReps
    nT = clock() nB = ByteScanIndexLimited(cBig, nLimit) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nIdxMs = nBest

if nA != nB
    raise("substr trap: the two paths disagree")
ok
? "CHECK substrtrap " + nA
? "TIME  substrtrap-substr " + Fmt(nSubMs)
? "TIME  substrtrap-index " + Fmt(nIdxMs)
TimerFloor("substrtrap-substr", nSubMs) TimerFloor("substrtrap-index", nIdxMs)

### B5. the for-header trap, priced on THIS machine ---------------
# `for i = 1 to len(s)` re-evaluates len(s) EVERY iteration, and every
# evaluation copies the whole string to the call. The loop is O(n^2) in
# the string size while looking O(n). Same body, same answer, one hoisted
# variable apart -- which is why it gets a timed pair rather than a
# comment: the number is the argument.
cTrap = copy("x", 60000 * nScale)

nBest = -1
for r = 1 to nReps
    nT = clock() nA = HeaderLen(cTrap) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nTrapMs = nBest

nBest = -1
for r = 1 to nReps
    nT = clock() nB = HoistedLen(cTrap) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
nHoistMs = nBest

if nA != nB
    raise("for-header trap: the two paths disagree")
ok
? "CHECK forheader " + nA
? "TIME  forheader-trap " + Fmt(nTrapMs)
? "TIME  forheader-hoisted " + Fmt(nHoistMs)
TimerFloor("forheader-hoisted", nHoistMs)

? ""
? "SUITE OK"

### ================================================================
###                          functions
### ================================================================

func Ms nStart
    return (clock() - nStart) / clockspersecond() * 1000

func Report cName, nMs, xCheck
    ? "CHECK " + cName + " " + xCheck
    ? "TIME  " + cName + " " + Fmt(nMs)
    TimerFloor(cName, nMs)

# clock() resolves to 1 ms here, so anything near it is a floor and not a
# value. Say so in the output rather than letting a reader treat 1.00 as a
# measurement -- the project's rule is "below the timer floor", never "0".
func TimerFloor cName, nMs
    if nMs < 5
        ? "WARN  " + cName + " at-timer-floor " + Fmt(nMs) + " ms - raise the scale"
    ok

# Two decimals without depending on how a platform renders a float.
func Fmt nX
    nR = floor(nX * 100 + 0.5)
    return "" + floor(nR / 100) + "." + Pad2(nR % 100)

func Pad2 n
    if n < 10 return "0" + n ok
    return "" + n

# Order-sensitive: a sort returning the right multiset in the wrong order
# must not pass.
func Sum32 aList
    nH = 0
    for i = 1 to len(aList)
        nH = (nH * 31 + aList[i]) % 1000000007
    next
    return nH

func StrSum cStr
    nH = 0
    # len() hoisted out of the header (F-41): `for i = 1 to len(s)`
    # re-evaluates len(s) every iteration, and each evaluation copies the
    # WHOLE string to the call. On the 200 KB patch string this checksum
    # was silently moving ~40 GB before the fix.
    nL = len(cStr)
    for i = 1 to nL
        nH = (nH * 131 + ascii(cStr[i])) % 1000000007
    next
    return nH

func Sieve nN
    aFlag = list(nN)
    nCount = 0
    for i = 2 to nN
        if aFlag[i] = 0
            nCount++
            j = i * i
            while j <= nN
                aFlag[j] = 1
                j += i
            end
        ok
    next
    return nCount

func MatMul nN
    aA = list(nN) aB = list(nN)
    for i = 1 to nN
        aA[i] = list(nN) aB[i] = list(nN)
        for j = 1 to nN
            aA[i][j] = (i + j) % 7
            aB[i][j] = (i * j) % 5
        next
    next
    nAcc = 0
    for i = 1 to nN
        aRow = aA[i]
        for j = 1 to nN
            nS = 0
            for k = 1 to nN
                nS += aRow[k] * aB[k][j]
            next
            nAcc = (nAcc + nS * (i + j)) % 1000000007
        next
    next
    return nAcc

func Fib n
    if n < 2 return n ok
    return Fib(n - 1) + Fib(n - 2)

func MergeSort aL
    if len(aL) <= 1 return aL ok
    nMid = floor(len(aL) / 2)
    aLeft = [] aRight = []
    for i = 1 to nMid aLeft + aL[i] next
    for i = nMid + 1 to len(aL) aRight + aL[i] next
    return Merge(MergeSort(aLeft), MergeSort(aRight))

func Merge aA, aB
    aOut = []
    i = 1 j = 1
    while i <= len(aA) and j <= len(aB)
        if aA[i] <= aB[j]
            aOut + aA[i] i++
        else
            aOut + aB[j] j++
        ok
    end
    while i <= len(aA) aOut + aA[i] i++ end
    while j <= len(aB) aOut + aB[j] j++ end
    return aOut

func BinSearchAll aSorted, nQueries
    nHits = 0
    nN = len(aSorted)
    for q = 1 to nQueries
        nTarget = (q * 7919) % (nN * 2)
        nLo = 1 nHi = nN
        while nLo <= nHi
            nMid = floor((nLo + nHi) / 2)
            if aSorted[nMid] = nTarget
                nHits++
                exit
            but aSorted[nMid] < nTarget
                nLo = nMid + 1
            else
                nHi = nMid - 1
            ok
        end
    next
    return nHits

func ByteScan cStr
    nH = 0
    # len() hoisted (F-41). Before this fix the benchmark measured the
    # for-header trap, not byte access: 80,000 iterations each copying an
    # 80 KB string is 6.4 GB of memcpy that LOOKED like slow indexing --
    # and it is also the shape Lua never pays, because Lua's numeric for
    # evaluates its bound once. The trap now has its own timed pair (B5).
    nL = len(cStr)
    for i = 1 to nL
        nH = (nH * 131 + ascii(cStr[i])) % 1000000007
    next
    return nH

func ByteScanSubstr cStr, nLimit
    nH = 0
    for i = 1 to nLimit
        nH = (nH * 131 + ascii(substr(cStr, i, 1))) % 1000000007
    next
    return nH

func ByteScanIndexLimited cStr, nLimit
    nH = 0
    for i = 1 to nLimit
        nH = (nH * 131 + ascii(cStr[i])) % 1000000007
    next
    return nH

func RawPatch nSize, nPatch, nStep, cPatch
    cBuf = copy("x", nSize)
    for i = 0 to nPatch - 1
        nOff = i * nStep
        cBuf = left(cBuf, nOff) + cPatch + substr(cBuf, nOff + len(cPatch) + 1)
    next
    return cBuf

func RppPatch nSize, nPatch, nStep, cPatch
    oBuf = new RppBuffer(nSize)
    oBuf.Fill(0, nSize, ascii("x"))
    for i = 0 to nPatch - 1
        oBuf.Poke(i * nStep, cPatch)
    next
    return oBuf.Str()

func RawSlices cStr, nSlices, nLen
    nH = 0
    nSpan = len(cStr) - nLen - 1
    for i = 1 to nSlices
        nOff = ((i * 7919) % nSpan) + 1
        cS = substr(cStr, nOff, nLen)
        nH = (nH * 131 + ascii(cS[1]) + ascii(cS[nLen])) % 1000000007
    next
    return nH

func RppSlices oBuf, nSlices, nLen
    nH = 0
    nSpan = oBuf.Size() - nLen - 1
    for i = 1 to nSlices
        nOff = ((i * 7919) % nSpan)
        cS = oBuf.Peek(nOff, nLen)
        nH = (nH * 131 + ascii(cS[1]) + ascii(cS[nLen])) % 1000000007
    next
    return nH

func RawReads aList, nReads
    nH = 0
    nN = len(aList)
    for i = 1 to nReads
        nIdx = ((i * 7919) % nN) + 1
        nH = (nH + aList[nIdx]) % 1000000007
    next
    return nH

func HeaderLen cStr
    nH = 0
    for i = 1 to len(cStr)
        nH += 1
    next
    return nH

func HoistedLen cStr
    nH = 0
    nL = len(cStr)
    for i = 1 to nL
        nH += 1
    next
    return nH
