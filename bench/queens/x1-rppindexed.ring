# N-Queens — X1. Ring++'s own list idiom, applied and REJECTED.
#
# RppIndexed exists because Ring reaches a list element by walking from a
# cursor, so a jumping access costs O(distance) — the finding that made
# binary search over an 8,000-item list 5x faster on a phone (F-42).
#
# The board here is at most 11 items. There is no distance to save: the
# cursor is never more than a few steps from the next read, and
# ringvm_genarray's own setup is paid once per board for a gain that never
# arrives.
#
# Measured: no improvement, inside the noise of the variant it wraps.
# Kept in the repository because a library that only ships the cases where
# it wins is advertising, not engineering. The rule this yields is a size
# rule, and it is the same one F-9/F-10 already state: the indexed idiom
# is for big lists read out of order, not for small ones read in order.

load "../../ringpp.ring"

nMax = 11
if len(sysargv) >= 3
    nMax = number(sysargv[3])
ok

countPlace = 0
countQueen = 0
countSol   = 0
x = 1:nMax

nT = clock()
for n = 1 to nMax
    x = 1:n
    oIdx = RppIndexed(x)
    nQueen(1, n)
    oIdx.Release(x)
next
nMs = (clock() - nT) / clockspersecond() * 1000

? "CHECK sol " + countSol
? "CHECK place " + countPlace
? "CHECK queen " + countQueen
? "TIME  total " + nMs

func Place k, i
    countPlace++
    for j = 1 to k-1
        if x[j] = i or fabs(x[j]-i) = k - j
            return 0
        ok
    next
    return 1


func nQueen k, n
    countQueen++
    for i = 1 to n
        if place(k, i)
            x[k] = i
            if k = n
                countSol++
            else
                nQueen(k+1, n)
            ok
        ok
    next
