# kernels.ring with Ring's PARAMETER TYPE ANNOTATIONS (F-24's free
# channel: a parser feature, no library needed, stock Ring runs it).
# Byte-for-byte the same algorithms as kernels.ring.
#
# This file is compiled two ways and the answers are diffed:
#   1. by Ring 1.27 itself      (ring kernels_run.ring)
#   2. by the Ring-Next front end into spike bytecode   (rnxc kernels.ring)
#
# It is deliberately restricted to the subset the front end compiles so far.
# The restrictions are real limitations, not stylistic choices, and each one
# is a named Stage 2 item:
#
#   - integers only. The VM has no doubles yet, so division appears only as
#     floor(a / b), which compiles to an integer divide.
#   - add(aList, x) rather than Ring's `aList + x` append operator.
#   - no NESTED path assignment (`aA[i][j] = v`). Under copy-on-write that
#     needs a get-for-write opcode that COWs each level and writes it back;
#     without one the write would land in a private clone and vanish. Rows
#     are therefore built and then added, which is what the hand-written
#     bytecode does anyway.
#   - no classes, no strings beyond len() and ascii(s[i]), no printing.
#     The driver calls these functions and prints; the file only defines.

func Sieve(int nN)
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

func MatMul(int nN)
    aA = []
    aB = []
    for i = 1 to nN
        aRowA = list(nN)
        aRowB = list(nN)
        for j = 1 to nN
            aRowA[j] = (i + j) % 7
            aRowB[j] = (i * j) % 5
        next
        add(aA, aRowA)
        add(aB, aRowB)
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

func Fib(int n)
    if n < 2 return n ok
    return Fib(n - 1) + Fib(n - 2)

func BuildData(int nN)
    aL = []
    for i = 1 to nN
        add(aL, (i * 7919) % 100003)
    next
    return aL

func Merge(list aA, list aB)
    aOut = []
    i = 1
    j = 1
    while i <= len(aA) and j <= len(aB)
        if aA[i] <= aB[j]
            add(aOut, aA[i])
            i++
        else
            add(aOut, aB[j])
            j++
        ok
    end
    while i <= len(aA)
        add(aOut, aA[i])
        i++
    end
    while j <= len(aB)
        add(aOut, aB[j])
        j++
    end
    return aOut

func MergeSort(list aL)
    if len(aL) <= 1 return aL ok
    nMid = floor(len(aL) / 2)
    aLeft = []
    aRight = []
    for i = 1 to nMid
        add(aLeft, aL[i])
    next
    nLen = len(aL)
    for i = nMid + 1 to nLen
        add(aRight, aL[i])
    next
    return Merge(MergeSort(aLeft), MergeSort(aRight))

func Sum32(list aL)
    nH = 0
    nN = len(aL)
    for i = 1 to nN
        nH = (nH * 31 + aL[i]) % 1000000007
    next
    return nH

func BinSearchAll(list aSorted, int nQueries)
    nHits = 0
    nN = len(aSorted)
    for q = 1 to nQueries
        nTarget = (q * 7919) % (nN * 2)
        nLo = 1
        nHi = nN
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
