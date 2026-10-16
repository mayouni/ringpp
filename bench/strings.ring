# The string workload, in plain Ring -- PRIVATE spike material.
#
#     ring strings.ring
#
# This is the workload the six F-39 algorithms never covered, and it is the
# one the whole project rests on: "a Ring string is copied every time it
# crosses a call boundary. A list is not." (F-1, F-5: ~2200x, ~750 us for a
# 1 MB argument.) Nothing in the algorithm suite passes a large string to a
# function, so nothing in it tests the founding thesis.
#
# Two kernels, both written the way ordinary Ring would write them:
#
#   strpass  calls a one-line function 2000 times with a 1 MB string. The
#            function returns len(s). All the work is the call boundary.
#   strfind  naive substring search, byte by byte with s[i], so every
#            runtime in the comparison does the same work.
#
# LAYOUT: every executable statement above the first `func` (F-21).

nReps = 3

cPart = "the quick brown fox "
cBig = copy(cPart, 50000)      # 1,000,000 bytes, built once
cPat = "fox"

? "Ring string workload"
? copy("=", 46)
? ""

### S1. pass a 1 MB string across a call boundary, 2000 times -------
nBest = -1
for r = 1 to nReps
    nT = clock() nV = StrPass(cBig, 2000) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("strpass", nBest, nV)

### S2. naive substring search over the same 1 MB ------------------
nBest = -1
for r = 1 to nReps
    nT = clock() nV = StrFind(cBig, cPat) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("strfind", nBest, nV)

? ""
? "SUITE OK"

func FLen s
    return len(s)

func StrPass s, n
    nTotal = 0
    for i = 1 to n
        nTotal += FLen(s)
    next
    return nTotal

func StrFind s, pat
    nN = len(s)
    nM = len(pat)
    nCount = 0
    nLim = nN - nM + 1
    for i = 1 to nLim
        lHit = 1
        for j = 1 to nM
            if s[i + j - 1] != pat[j]
                lHit = 0
                exit
            ok
        next
        if lHit = 1
            nCount++
        ok
    next
    return nCount

func Ms nStart
    return (clock() - nStart) / clockspersecond() * 1000

func Report cName, nMs, xCheck
    ? "CHECK " + cName + " " + xCheck
    ? "TIME  " + cName + " " + Fmt(nMs)

func Fmt nMs
    nH = floor(nMs * 100 + 0.5)
    return "" + (nH / 100) + "." + Pad2(nH % 100)

func Pad2 n
    if n < 10 return "0" + n ok
    return "" + n
