# What it costs to carry a number as a string, which is the only way to
# keep its own precision through a Ring program.
# A/B, minima over 5 reps, differing in one thing: the representation.

nIter = 200000
nReps = 5

# --- A: native double arithmetic
nA = 999999999
for r = 1 to nReps
    t = clock()
    acc = 0
    for i = 1 to nIter
        acc = acc + 1.5
    next
    e = clock() - t
    if e < nA nA = e ok
next

# --- B: the same sum, carried as a string between operations
nB = 999999999
for r = 1 to nReps
    t = clock()
    cAcc = "0"
    for i = 1 to nIter
        cAcc = "" + (number(cAcc) + 1.5)
    next
    e = clock() - t
    if e < nB nB = e ok
next

? "iterations        : " + nIter
? "native      (ms)  : " + nA
? "via string  (ms)  : " + nB
? "ratio             : " + (nB / nA)
