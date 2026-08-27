# N-Queens — V1. One fabs() removed, and nothing else.
#
# THE ONLY CHANGE from V0, in one line of Place():
#
#     fabs(j-k)   ->   k - j
#
# The loop header is `for j = 1 to k-1`, so j is ALWAYS less than k and
# j-k is always negative. fabs() was being called 9,015,683 times to
# compute a sign the loop had already fixed.
#
# WHAT WAS TRIED AND REJECTED, because measuring it is the whole point:
#
#   killing the SECOND fabs too, as `x[j]-i = k-j or i-x[j] = k-j`
#       ... SLOWER. One builtin call beats two extra comparisons.
#   hoisting x[j] into a local before the test
#       ... SLOWER. The assignment costs more than the second read saves.
#   carrying k-j in a counter (nD--) instead of recomputing it
#       ... SLOWER. Same reason: the decrement is an assignment.
#
# Measured unit costs on Ring 1.27 explain all three: an assignment costs
# ~20 ns and a fabs() call ~21 ns, so trading a call for an assignment
# buys nothing, and paying an assignment to save one list read loses.
# "Fewer function calls" is not a Ring optimisation on its own.
#
# All three counters must match V0 exactly: the search is untouched.

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
    nQueen(1, n)
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
