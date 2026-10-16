load "kernels_typed.ring"

? "CHECK sieve " + Sieve(300000)
? "CHECK matmul " + MatMul(80)
? "CHECK fib " + Fib(25)
aData = BuildData(8000)
aSorted = MergeSort(aData)
? "CHECK mergesort " + Sum32(aSorted)
? "CHECK binsearch " + BinSearchAll(aSorted, 6000)
? "SUITE OK"
