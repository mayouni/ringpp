# N-Queens — V0, the original, made measurable.
#
# SOURCE. Queens-N-Timing.ring as received. Its own header credits the
# algorithm to VIKASH VIK VIKASHVVERMA (programminggeek.in); the timing
# harness around it is the adaptation being studied here.
#
# WHAT CHANGED FROM THE FILE AS RECEIVED, and nothing else:
#
#   1. `Give n` / `Give m` removed. A program that stops for a human cannot
#      be benchmarked, cannot run in a gate, and cannot be compared against
#      anything. The board size comes from the command line instead.
#   2. A solution counter at the leaf. The original reaches `if k=n` and
#      does nothing there -- the printing is commented out -- so it never
#      learns how many solutions it found. One increment makes the program
#      verifiable: N-Queens solution counts are published constants, so a
#      variant that is faster and WRONG can no longer pass.
#   3. `showDisplay` dropped. It was already unreachable (its only call is
#      commented out) and it reads the global x.
#
# The SEARCH is untouched: same Place(), same nQueen(), same recursion,
# same globals, same fabs() calls. Every later variant must reproduce this
# file's three counters exactly, or its timing means nothing.

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
        if (x[j] = i or fabs(x[j]-i) = fabs(j-k))
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
