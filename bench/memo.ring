# What `#rpp: cache` costs and what it buys -- measured BEFORE the feature.
#
# Every case below hand-writes exactly what the transform would generate:
# the original body moves to F__rpp_impl, and F becomes a wrapper that
# builds a key, probes the store, and fills it on a miss. Recursive calls
# inside the body still name F, so they re-enter the WRAPPER -- which is
# the whole reason memoised fib stops being exponential.
#
# Minima over repetitions. The store is a Ring string-keyed list, measured
# O(1): 0.25 / 0.20 / 0.30 us at 100 / 1,000 / 10,000 entries.
#
# A miss returns "" rather than raising, and "" is a legal cached VALUE, so
# a hit is wrapped in a one-element list: isList() is the presence test.

$aRppMemo = []

func RppMemoGet(cKey)
	return $aRppMemo[cKey]

func RppMemoPut(cKey, xVal)
	$aRppMemo[cKey] = [ xVal ]

func RppMemoReset()
	$aRppMemo = []

# ---------------------------------------------------------------- case 1
# Recursive, exponential without a cache. The shape the feature is for.

func Fib(n)
	_k_ = "Fib" + char(31) + n
	_h_ = $aRppMemo[_k_]
	if isList(_h_) return _h_[1] ok
	_v_ = Fib__rpp_impl(n)
	$aRppMemo[_k_] = [ _v_ ]
	return _v_

func Fib__rpp_impl(n)
	if n < 2 return n ok
	return Fib(n-1) + Fib(n-2)

func FibPlain(n)
	if n < 2 return n ok
	return FibPlain(n-1) + FibPlain(n-2)

# ---------------------------------------------------------------- case 2
# Trivial body, cheap key. The cache cannot win: it adds a string build and
# a store probe to an addition.

func Add(a, b)
	_k_ = "Add" + char(31) + a + char(31) + b
	_h_ = $aRppMemo[_k_]
	if isList(_h_) return _h_[1] ok
	_v_ = Add__rpp_impl(a, b)
	$aRppMemo[_k_] = [ _v_ ]
	return _v_

func Add__rpp_impl(a, b)
	return a + b

func AddPlain(a, b)
	return a + b

# ---------------------------------------------------------------- case 3
# A LIST argument. The key must serialise it, and that is the thesis of
# this whole project arriving as a cost: the bigger the argument, the more
# the key costs, whether or not the answer was already there.

func Sum(aL)
	_k_ = "Sum" + char(31) + list2str(aL)
	_h_ = $aRppMemo[_k_]
	if isList(_h_) return _h_[1] ok
	_v_ = Sum__rpp_impl(aL)
	$aRppMemo[_k_] = [ _v_ ]
	return _v_

func Sum__rpp_impl(aL)
	s = 0
	nLen = len(aL)
	for i = 1 to nLen s += aL[i] next
	return s

func SumPlain(aL)
	s = 0
	nLen = len(aL)
	for i = 1 to nLen s += aL[i] next
	return s

func Head(aL)
	_k_ = "Head" + char(31) + list2str(aL)
	_h_ = $aRppMemo[_k_]
	if isList(_h_) return _h_[1] ok
	_v_ = Head__rpp_impl(aL)
	$aRppMemo[_k_] = [ _v_ ]
	return _v_

func Head__rpp_impl(aL)
	return aL[1]

func HeadPlain(aL)
	return aL[1]

# ---------------------------------------------------------------------
func Best(nReps, cWhat, nArg, aArg)
	nBest = -1
	for r = 1 to nReps
		RppMemoReset()
		t1 = clock()
		switch cWhat
		on :fib      v = Fib(nArg)
		on :fibplain v = FibPlain(nArg)
		on :add      for i = 1 to nArg v = Add(i % 50, 7) next
		on :addplain for i = 1 to nArg v = AddPlain(i % 50, 7) next
		on :sum      for i = 1 to nArg v = Sum(aArg) next
		on :sumplain for i = 1 to nArg v = SumPlain(aArg) next
		on :head     for i = 1 to nArg v = Head(aArg) next
		on :headplain for i = 1 to nArg v = HeadPlain(aArg) next
		off
		t2 = clock()
		d = t2 - t1
		if nBest = -1 or d < nBest nBest = d ok
	next
	return nBest

func Row(cName, nPlain, nMemo)
	cVerdict = "cache WINS"
	if nMemo > nPlain cVerdict = "cache LOSES" ok
	nRatio = 0
	if nMemo > 0 nRatio = nPlain / nMemo ok
	# clock() resolves to 1 ms, so a cached run that reports 0 is not 0 --
	# it is BELOW THE FLOOR, and the honest speedup is a lower bound.
	if nMemo = 0
		? "  " + cName + "  plain " + nPlain + " ms   cached below 1 ms   > " + nPlain + "x   cache WINS"
	but nPlain = 0
		? "  " + cName + "  plain below 1 ms   cached " + nMemo + " ms   cache LOSES"
	else
		? "  " + cName + "  plain " + nPlain + " ms   cached " + nMemo + " ms   " + nRatio + "x   " + cVerdict
	ok

func main
	? "#rpp: cache -- measured, minima of 3, Ring 1.27"
	? ""

	aBig = 1:50

	Row("fib(28), recursive        ", Best(3, :fibplain, 28, []), Best(3, :fib, 28, []))
	Row("Add(a,b) x 200,000        ", Best(3, :addplain, 200000, []), Best(3, :add, 200000, []))
	Row("Sum(50-list) x 100,000    ", Best(3, :sumplain, 100000, aBig), Best(3, :sum, 100000, aBig))
	Row("Head(50-list) x 100,000   ", Best(3, :headplain, 100000, aBig), Best(3, :head, 100000, aBig))

	? ""
	? "The first row is what the feature is for. The other two are what it"
	? "costs when it is used on the wrong shape -- and nothing in the source"
	? "distinguishes them, which is why the anchor must be written by hand"
	? "and never inferred."
