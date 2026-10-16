load "oo.ring"

nReps = 3
nN = 200000

nBest = -1
for r = 1 to nReps
    nT = clock() nV = UseCounter(nN) nMs = (clock() - nT) / clockspersecond() * 1000
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
? "CHECK usecounter " + nV
? "TIME  usecounter " + nBest

nBest = -1
for r = 1 to nReps
    nT = clock() nV = UseInherit(nN) nMs = (clock() - nT) / clockspersecond() * 1000
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
? "CHECK useinherit " + nV
? "TIME  useinherit " + nBest
