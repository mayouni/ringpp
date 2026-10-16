# What it costs to find a LIST inside a list, because find() cannot.
#
#   (a) native find() over a list of STRINGS -- what Ring supports
#   (b) the stringify workaround over the same data held as LISTS --
#       what you must do when the items are lists or objects
#
# clock() has 1 ms resolution, so each search is repeated until the
# measurement is well above the floor. Minima over 5 repetitions.

nN = 2000
nSearches = 2000
nReps = 5

aStrings = []
aLists = []
for i = 1 to nN
    add(aStrings, "item" + i + "|" + (i*2))
    add(aLists, [ "item" + i, i*2 ])
next

cTarget = "item" + nN + "|" + (nN*2)
aTarget = [ "item" + nN, nN*2 ]

# --- (a) native find over strings
nA = 999999999
for r = 1 to nReps
    t = clock()
    for s = 1 to nSearches
        n = find(aStrings, cTarget)
    next
    e = clock() - t
    if e < nA nA = e ok
next

# --- (b) stringify-and-scan, because find() returns 0 for lists
nB = 999999999
for r = 1 to nReps
    t = clock()
    for s = 1 to nSearches
        cWant = ""
        nTL = len(aTarget)
        for j = 1 to nTL cWant += "" + aTarget[j] + "|" next
        nFound = 0
        nLen = len(aLists)
        for i = 1 to nLen
            cRow = ""
            aRow = aLists[i]
            nRL = len(aRow)
            for j = 1 to nRL cRow += "" + aRow[j] + "|" next
            if cRow = cWant nFound = i exit ok
        next
    next
    e = clock() - t
    if e < nB nB = e ok
next


# --- (c) stringify ONCE, then native find. Honest counterpoint: if the
#     list never changes, the cost is paid once. It is (b) that a live,
#     mutating list pays, on every search.
nC = 999999999
for r = 1 to nReps
    t = clock()
    aCache = []
    nLen2 = len(aLists)
    for i = 1 to nLen2
        cRow = ""
        aRow = aLists[i]
        nRL = len(aRow)
        for j = 1 to nRL cRow += "" + aRow[j] + "|" next
        add(aCache, cRow)
    next
    cWant2 = ""
    nTL2 = len(aTarget)
    for j = 1 to nTL2 cWant2 += "" + aTarget[j] + "|" next
    for s = 1 to nSearches
        n = find(aCache, cWant2)
    next
    e = clock() - t
    if e < nC nC = e ok
next

? "build-once + 200 finds  (ms) : " + nC
? "  (the one-off build is " + (nC - nA) + " ms of that)"

? "items per list               : " + nN
? "searches per timed run       : " + nSearches
? "native find on strings  (ms) : " + nA
? "stringify scan on lists (ms) : " + nB
? "per search, native      (us) : " + (nA * 1000 / nSearches)
? "per search, stringify   (us) : " + (nB * 1000 / nSearches)
? "ratio                        : " + (nB / nA)
