# The price of C-7 (Ring's copy at assignment), row by row, on two binaries:
#   rnxc time bench/copyprice.ring <Row> <n> 5
# Sieve, MatMul, Fib: no list is ever assigned or returned -- the floor.
# SortN: MergeSort RETURNS a list variable at every level, so every level
#   now copies -- the pattern the change hurts most in real code.
# AssignN: a list of n assigned 1000 times -- the worst case, on purpose.
# ParamN: a callee appending through its PARAMETER 1000 times -- what the
#   old clone-on-write got wrong (and cloned), and what by-reference fixes.
load "kernels.ring"
func SortN nN
	aL = BuildData(nN)
	aS = MergeSort(aL)
	return len(aS)
func AssignN nN
	aL = BuildData(nN)
	nTotal = 0
	for i = 1 to 1000
		aB = aL
		nTotal = nTotal + len(aB)
	next
	return nTotal
func ParamN nN
	aL = []
	for i = 1 to 1000
		Append(aL, nN)
	next
	return len(aL)
func Append aTo, nHow
	for j = 1 to nHow
		add(aTo, j)
	next
