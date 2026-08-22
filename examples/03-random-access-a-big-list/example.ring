# Ring++ example 03 -- random access into a big list
#
# THE MOST SURPRISING RESULT IN THIS PROJECT, and the one that changes how
# you read your own code:
#
#     HOW A LIST WAS BUILT DECIDES WHAT IT COSTS TO READ.
#
# A Ring list is a linked list with a one-entry cursor cache. Walking it in
# order is fast, because every step hits the cache. Jumping around it is
# O(n) PER READ, because each jump walks from the head.
#
# So `aList[i]` -- the plainest expression in the language -- is cheap or
# quadratic depending on whether your i values happen to ascend. Nothing in
# the source distinguishes the two. (FINDINGS F-19.)
#
# THE TASK, which is ordinary: a lookup table, probed in an order that is
# not the order it was built in. A join. A scatter. Anything driven by keys
# arriving from outside.
#
# WHAT RING++ DOES: `ringvm_genarray` asks the VM to build a real pointer
# array for the list, making index access O(1). RppIndexed wraps that as a
# PHASE -- you open it, read, and close it -- because ONE structural
# mutation frees the array and silently returns you to walking.
#
# NOTE THE DIFF. The reading loop is IDENTICAL in both versions. Ring++ is
# two lines around it. That is the whole intervention.

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nItems = 20000     # rows in the table
nReads = 20000     # probes, in permuted order
nReps  = 3

# Built by appending, which is how lists are usually built -- and which
# leaves no items array behind.
aList = []
for i = 1 to nItems
    aList + (i * 3)
next

? "Ring++ example 03 -- random access into a big list"
? copy("-", 58)
? "items  : " + nItems + " (built by appending)"
? "reads  : " + nReads + " in PERMUTED order"
? "        (in ASCENDING order the cursor cache hides the cost entirely)"
? ""

### ------------------------------------------------------------- raw Ring

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nRaw = RawWay(aList, nReads, nItems)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### --------------------------------------------------------------- Ring++

nRppBest = 0
bIndexApplied = FALSE
bStillValid = FALSE
for r = 1 to nReps
    nT = clock()
    oIdx = new RppIndexed(aList)          # <-- open the phase
    nRpp = ReadLoop(aList, nReads, nItems)
    bStillValid = oIdx.Release(aList)     # <-- close it
    nMs = (clock() - nT) / clockspersecond() * 1000
    bIndexApplied = oIdx.Applied()
    if r = 1 or nMs < nRppBest
        nRppBest = nMs
    ok
next

### -------------------------------------------------- correctness, first

bSame = (nRaw = nRpp)
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- raw sum " + nRaw + " vs Ring++ sum " + nRpp
ok
? ""

### ----------------------------------------------------------- the number

? "raw Ring        : " + RppMs(nRawBest)
? "Ring++          : " + RppMs(nRppBest)
if nRppBest > 0
    ? "speedup         : " + floor(nRawBest / nRppBest) + "x"
else
    ? "speedup         : Ring++ below the 1 ms timer floor"
ok
? ""
? "index applied   : " + bIndexApplied
? "still valid at close : " + bStillValid + "  (FALSE would mean the list"
? "                       changed size mid-phase and reads went back to walking)"
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES:"
? "  Below " + RPP_INDEX_MIN_SIZE + " items RppIndexed REFUSES -- the walk is cheaper than"
? "  the array. It tells you why rather than pretending to help."
? "  Worse: if you MUTATE the list during the phase, every append frees"
? "  the array and it is rebuilt on the next read. Write-heavy code pays"
? "  up to 16x for this (FINDINGS F-9, F-10). Open the phase AFTER the"
? "  mutations, never around them."
? ""
? "  And it cannot see everything: " + Caveat()
? ""
? "EXAMPLE 03 OK"

### =====================================================================

func RawWay aList, nReads, nItems
    # No index. Identical body to ReadLoop below -- that is the point.
    return ReadLoop(aList, nReads, nItems)

func ReadLoop aList, nReads, nItems
    # The reading loop. UNCHANGED between the two versions.
    #
    # Park-Miller, not `i * k % n`: a stride that ascends is cursor-friendly
    # and would make "random" reads fast for the wrong reason. Measuring the
    # wrong sequence is how the first version of FINDINGS F-19 got its
    # numbers wrong.
    nSum = 0
    nSeed = 1
    for i = 1 to nReads
        nSeed = (nSeed * 16807) % 2147483647
        nSum += aList[(nSeed % nItems) + 1]
    next
    return nSum

func Caveat
    oTmp = new RppIndexed([])
    return oTmp.Caveat()

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
