# Runs kernels.ring under Ring 1.27 and prints the CHECK lines the
# Ring-Next front end must reproduce byte for byte.
#
#     ring kernels_run.ring
#
# Main program above the first func (F-21) -- here there are no funcs at
# all, they arrive with the load.

load "kernels.ring"

? "CHECK sieve " + Sieve(300000)
? "CHECK matmul " + MatMul(80)
? "CHECK fib " + Fib(25)

aData = BuildData(8000)
aSorted = MergeSort(aData)
? "CHECK mergesort " + Sum32(aSorted)
? "CHECK binsearch " + BinSearchAll(aSorted, 6000)
? "SUITE OK"
