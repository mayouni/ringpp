# N-Queens — V2. The inner loop deleted, not optimised.
#
# V0 and V1 both ask the same question 9,015,683 times: "does this square
# conflict with any queen already placed?" — and answer it by walking every
# queen placed so far. That walk is why the program spends its life in
# Place().
#
# The standard answer is to stop asking. A queen at (k,i) conflicts with an
# earlier one exactly when it shares a column, a diagonal, or an
# anti-diagonal — and each of those is a single number:
#
#     column          i
#     diagonal        k + i     (constant along one diagonal)
#     anti-diagonal   k - i     (constant along the other)
#
# Keep one flag per value and the test is three list reads instead of a
# loop. The cost of a placement stops depending on how deep the search is.
#
# THE PRICE, stated because it is real: marking and unmarking costs six
# list writes per node, so this trades an O(k) test for O(1) test plus O(1)
# bookkeeping. It wins because the inner loop was long; on a tiny board it
# would not.
#
# `countPlace` no longer means the same thing — there is no inner loop to
# count — so it is not compared against V0/V1. `countSol` is, and it is the
# check that matters: the published N-Queens counts do not move because an
# implementation got faster.

nMax = 11
if len(sysargv) >= 3
    nMax = number(sysargv[3])
ok

countQueen = 0
countSol   = 0
x = 1:nMax
aCol = list(nMax)
aD1  = list(2*nMax + 2)     # k+i, from 2 to 2n
aD2  = list(2*nMax + 2)     # k-i+n, from 1 to 2n-1

nT = clock()
for n = 1 to nMax
    x = 1:n
    aCol = list(n)
    aD1  = list(2*n + 2)
    aD2  = list(2*n + 2)
    nQueen(1, n)
next
nMs = (clock() - nT) / clockspersecond() * 1000

? "CHECK sol " + countSol
? "CHECK queen " + countQueen
? "TIME  total " + nMs

func nQueen k, n
    countQueen++
    for i = 1 to n
        nA = k + i
        nB = k - i + n
        if aCol[i] = 0 and aD1[nA] = 0 and aD2[nB] = 0
            aCol[i] = 1  aD1[nA] = 1  aD2[nB] = 1
            x[k] = i
            if k = n
                countSol++
            else
                nQueen(k+1, n)
            ok
            aCol[i] = 0  aD1[nA] = 0  aD2[nB] = 0
        ok
    next
