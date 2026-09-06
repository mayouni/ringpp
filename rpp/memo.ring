# Ring++ -- the store behind `#rpp: cache`.
#
# Nothing here is called by hand. `ringpp` rewrites an annotated function
# into a wrapper that probes this store and an implementation that does the
# work, and the wrapper is what calls these. Loading this file changes
# nothing on its own.
#
# WHY A RING LIST IS THE STORE. Ring grows a string-keyed list in place
# (`aH["k"] = v`) and looks it up in constant time -- measured 0.25, 0.20
# and 0.30 us at 100, 1,000 and 10,000 entries, flat. There is nothing to
# beat here and no reason to leave the language, which is the whole brief.
#
# WHY A HIT IS WRAPPED IN A LIST. A missing key returns "" rather than
# raising, and "" is a legal cached VALUE. Storing [ xVal ] makes isList()
# the presence test, so a function that legitimately returns "" is cached
# correctly instead of being recomputed forever.
#
# WHAT IT COSTS, measured on Ring 1.27 (bench/memo.ring, minima of 3):
#
#     fib(28), recursive         95 ms  ->  below 1 ms      > 95x   WINS
#     Sum(50-list) x 100,000    574 ms  ->  501 ms          1.15x   wins
#     Add(a,b)     x 200,000     37 ms  ->  336 ms          0.11x   LOSES
#     Head(50-list) x 100,000    20 ms  ->  502 ms          0.04x   LOSES
#
# The two losses are the point. Building the key costs 0.13 us for a number
# and 2.62 us for a 50-item list, and that is paid on EVERY call, hit or
# miss. So the cache pays when the body is expensive relative to its
# arguments, and it is a 25x pessimisation when the argument is large and
# the body is trivial. Nothing in the source distinguishes those two, which
# is why the anchor is written by hand and never inferred.

$aRppMemo   = []
$nRppHits   = 0
$nRppMisses = 0

# One argument, as a key fragment. Generated wrappers call this once per
# parameter -- a call rather than a list, so no list is allocated per call.
#
# A LIST costs list2str: 2.62 us for 50 items against 0.13 us for a number,
# and that is the whole difference between the two loss cases in the
# benchmark above. An OBJECT has no stable text here, so a cache keyed on
# one is not supported; that is a limit of the feature, not of this line.
func RppK(x)
	if isList(x) return list2str(x) ok
	return "" + x

# The cached value for cKey, or "" when there is none. Callers test with
# isList(), never against "" -- see the note above.
func RppMemoGet(cKey)
	_xRmgHit_ = $aRppMemo[cKey]
	if isList(_xRmgHit_)
		$nRppHits++
	else
		$nRppMisses++
	ok
	return _xRmgHit_

func RppMemoPut(cKey, xVal)
	$aRppMemo[cKey] = [ xVal ]
	return xVal

# Everything the store holds, and what it has been worth. A cache with a
# low hit rate is a pessimisation wearing a feature's clothes, and this is
# how its owner finds out.
func RppMemoStats()
	_nRmsTotal_ = $nRppHits + $nRppMisses
	_nRmsRate_ = 0
	if _nRmsTotal_ > 0
		_nRmsRate_ = ($nRppHits * 100) / _nRmsTotal_
	ok
	return [
		:entries = len($aRppMemo),
		:hits    = $nRppHits,
		:misses  = $nRppMisses,
		:rate    = _nRmsRate_
	]

func RppMemoShow()
	_aRmshS_ = RppMemoStats()
	? "rpp cache: " + _aRmshS_[:entries] + " entries, " +
	  _aRmshS_[:hits] + " hits, " + _aRmshS_[:misses] + " misses, " +
	  _aRmshS_[:rate] + "% hit rate"

func RppMemoReset()
	$aRppMemo   = []
	$nRppHits   = 0
	$nRppMisses = 0
