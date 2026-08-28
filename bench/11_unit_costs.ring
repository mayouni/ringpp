# Unit costs in a Ring loop body. 5,000,000 iterations, minimum of 3.
# Each row adds exactly ONE operation to the row above it in kind.
nIter = 5000000
aX = 1:12
i = 5
k = 9
j = 3

? "per-iteration cost, nanoseconds (minimum of 3 runs of 5M)"
? ""
nBase = Best(nIter, 0)
? "empty loop            " + Ns(nBase, nIter)
? "  + y = 1             " + Ns(Best(nIter,1) , nIter) + "   assignment"
? "  + y++               " + Ns(Best(nIter,2) , nIter) + "   increment"
? "  + if fabs(-5) = 5   " + Ns(Best(nIter,3) , nIter) + "   builtin call in a test"
? "  + if aX[3] = 5      " + Ns(Best(nIter,4) , nIter) + "   list read in a test"
? "  + if k - j = 5      " + Ns(Best(nIter,5) , nIter) + "   arithmetic in a test"
? "  + y = aX[3]         " + Ns(Best(nIter,6) , nIter) + "   list read INTO a local"

func Best nIter, nKind
    nB = -1
    for r = 1 to 3
        nT = clock()
        Run(nIter, nKind)
        nMs = (clock() - nT) / clockspersecond() * 1000
        if nB < 0 or nMs < nB nB = nMs ok
    next
    return nB

func Ns nMs, nIter
    return "" + floor(nMs * 1000000 / nIter) + " ns"

func Run nIter, nKind
    aX = 1:12
    y = 0
    k = 9
    j = 3
    switch nKind
    on 0
        for q = 1 to nIter
        next
    on 1
        for q = 1 to nIter
            y = 1
        next
    on 2
        for q = 1 to nIter
            y++
        next
    on 3
        for q = 1 to nIter
            if fabs(-5) = 5 y = 1 ok
        next
    on 4
        for q = 1 to nIter
            if aX[3] = 5 y = 1 ok
        next
    on 5
        for q = 1 to nIter
            if k - j = 5 y = 1 ok
        next
    on 6
        for q = 1 to nIter
            y = aX[3]
        next
    off
