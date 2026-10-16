# Times kernels.ring under Ring 1.27, so the SAME SOURCE can be compared
# against what the Ring-Next front end makes of it.
#
#     ring kernels_bench.ring
#
# Same harness as the campaign: minimum over repetitions, never a single
# run, and the CHECK values printed rather than asserted against constants.

load "kernels.ring"

nReps = 3

nBest = -1
for r = 1 to nReps
    nT = clock() nV = Sieve(300000) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("sieve", nBest, nV)

nBest = -1
for r = 1 to nReps
    nT = clock() nV = MatMul(80) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("matmul", nBest, nV)

nBest = -1
for r = 1 to nReps
    nT = clock() nV = Fib(25) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("fib", nBest, nV)

aData = BuildData(8000)
nBest = -1
for r = 1 to nReps
    nT = clock() aSorted = MergeSort(aData) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("mergesort", nBest, Sum32(aSorted))

nBest = -1
for r = 1 to nReps
    nT = clock() nV = BinSearchAll(aSorted, 6000) nMs = Ms(nT)
    if nBest < 0 or nMs < nBest nBest = nMs ok
next
Report("binsearch", nBest, nV)

? "SUITE OK"

func Ms nStart
    return (clock() - nStart) / clockspersecond() * 1000

func Report cName, nMs, xCheck
    ? "CHECK " + cName + " " + xCheck
    ? "TIME  " + cName + " " + Fmt(nMs)

func Fmt nMs
    nH = floor(nMs * 100 + 0.5)
    return "" + (nH / 100) + "." + Pad2(nH % 100)

func Pad2 n
    if n < 10 return "0" + n ok
    return "" + n
