# What is a native hashlist type actually worth in Ring++?
#
#     ring hashcost.ring
#
# NOT lookup complexity. Ring already builds a hash index for lists used
# as hashes -- the HashTable/HashItem structures in its own VM. Measured
# below: keyed lookup is FLAT from 10 entries to 5,000, ~0.15 us. Any
# argument for a map type resting on "O(1) instead of a scan" is
# unfounded, and an earlier draft of the charter made exactly that
# mistake.
#
# The real value, measured separately:
#   * a read that does not WRITE  -- reading a missing key grows the
#     container, len 2 -> 3 (the §2.2 defect)
#   * memory -- 200k hash entries peak at 73 MB against 17 MB for 200k
#     plain items, ~315 bytes per entry; a native entry is nearer 48
#   * a type that can be REQUIRED -- type() says LIST for both a hash
#     and a list of pairs, so no signature can ask for a map
#   * speed as a CONSTANT FACTOR -- keyed 0.15 us vs integer index
#     0.06 us, 2.73x; worth having, not the headline

# Is a Ring "hash" lookup O(1) or a scan? Build lists of N pairs and
# look up the LAST key (worst case for a scan, same cost for a map).
# Minima over 5 reps, enough lookups to clear clock()'s 1 ms floor.

aSizes = [10, 100, 1000, 5000]
nReps = 5
nLookups = 200000

for nN in aSizes
    aH = []
    for i = 1 to nN
        add(aH, ["key" + i, i])
    next
    cLast = "key" + nN

    nBest = 999999999
    for r = 1 to nReps
        t = clock()
        for k = 1 to nLookups
            v = aH[cLast]
        next
        e = clock() - t
        if e < nBest nBest = e ok
    next
    ? "  N = " + nN + "   " + nBest + " ms / " + nLookups + " lookups   = " +
      (nBest * 1000 / nLookups) + " us per lookup"
next
