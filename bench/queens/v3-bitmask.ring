# N-Queens — V3. The flags become bits, and the lists disappear.
#
# V2 replaced the O(k) scan with three list lookups. The lists are still
# lists: every placement writes six of them and undoes them on the way
# back out, and V2's own unit costs say a list write is among the more
# expensive things a Ring loop can do.
#
# The three occupancy sets are each at most n bits wide, and n <= 12 here,
# so all three fit in ordinary Ring numbers. Marking a square becomes an
# OR, testing it an AND, and unmarking is free — the caller's own copy of
# the mask was never modified, so recursion undoes it by returning.
#
#     colMask   bit i set  ->  column i taken
#     d1        shifted LEFT  each level: a diagonal moves one column per row
#     d2        shifted RIGHT each level: the anti-diagonal moves the other way
#
# The shift is what makes the bit form work: instead of indexing a
# diagonal by k+i, the whole set is slid one position per row so that
# "diagonal conflict" is always "same bit position as the column". That is
# the trick the bitmask formulation is famous for, and it is why no
# unmarking is needed.
#
# `& all` keeps the masks inside n bits, so shifting cannot leak a bit
# past the edge of the board and forbid a legal square.
#
# The recursion no longer needs the board at all, so `x` is gone. What it
# CANNOT report is countPlace/countQueen in V0's sense -- there is no
# placement test to count. countSol is the invariant, and it is checked.

nMax = 11
if len(sysargv) >= 3
    nMax = number(sysargv[3])
ok

countSol = 0

nT = clock()
for n = 1 to nMax
    nAll = (1 << n) - 1
    Solve(0, 0, 0, nAll)
next
nMs = (clock() - nT) / clockspersecond() * 1000

? "CHECK sol " + countSol
? "TIME  total " + nMs

func Solve nCol, nD1, nD2, nAll
    if nCol = nAll
        countSol++
        return
    ok
    # Every square not already attacked, as a bit set. Ring has no unsigned
    # complement, so the free squares are found by masking against nAll
    # rather than by inverting.
    nFree = nAll & ~(nCol | nD1 | nD2)
    while nFree != 0
        # lowest set bit: the classic two's-complement isolate
        nBit = nFree & -nFree
        nFree -= nBit
        Solve(nCol | nBit, ((nD1 | nBit) << 1) & nAll, (nD2 | nBit) >> 1, nAll)
    end
