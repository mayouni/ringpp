# A statement that begins with a name and `=` is an ASSIGNMENT of everything after the `=` on Ring (the assignment flag,
# expr.c:397). The grammar reads each `_bOk_ = ... and ...` below as an `and` chain whose LEFTMOST operand is the
# comparison `_bOk_ = isNumber(pnLon0)` -- in a method shaped exactly like this one (stzGeoFeatures.ring:792); drop any of
# its four statements and the grammar reads the assignment again (F-58's tie-break, F-138). Compiled as read, the
# assignment never happened: K's read of `_bOk_` was R24, K2's read the attribute's stale 1 with no error (Ring: 0), and
# K3's error inside the chain was never reached. Each class keeps the method's four statements as they are, on purpose.
# The oracle and the official 1.27 agree on every line.
o = new K
try
	? len(o.IndicesWithin(1, 2, 3, 4))
catch
	? "ERR " + cCatchError
done
o2 = new K2
try
	o2.IndicesWithin(1, 2, 3, "x")
	? o2._bOk_
catch
	? "ERR " + cCatchError
done
o3 = new K3
try
	o3.IndicesWithin(1, 2, 3, 4)
catch
	? "ERR " + cCatchError
done
try
catch
done
o3.IndicesWithin(1, 2, 3, 4)
? "NOT REACHED"
class K
	@aFeat = []
	def IndicesWithin(pnLon0, pnLat0, pnLon1, pnLat1)
		_bOk_ = isNumber(pnLon0) and isNumber(pnLat0) and isNumber(pnLon1) and isNumber(pnLat1)
		if _bOk_
		ok
		if NOT _bOk_
		ok
		for _i_ = 1 to len(@aFeat)
		next
class K2
	@aFeat = []
	_bOk_ = 1
	def IndicesWithin(pnLon0, pnLat0, pnLon1, pnLat1)
		_bOk_ = isNumber(pnLon0) and isNumber(pnLat0) and isNumber(pnLon1) and isNumber(pnLat1)
		if _bOk_
		ok
		if NOT _bOk_
		ok
		for _i_ = 1 to len(@aFeat)
		next
class K3
	@aFeat = []
	def IndicesWithin(pnLon0, pnLat0, pnLon1, pnLat1)
		_bOk_ = isNumber(pnLon0) and isNumber(pnLat0) and isNumber(pnLon1) and NoSuchFunc(pnLat1)
		if _bOk_
		ok
		if NOT _bOk_
		ok
		for _i_ = 1 to len(@aFeat)
		next
