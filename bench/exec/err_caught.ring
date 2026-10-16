# Caught, the message alone -- no `Line`, no chain -- and R3 for an
# undefined callee is catchable on Ring (it used to exit here).
try
	x = nosuch()
catch
	? "[" + cCatchError + "]"
done
try
	o = new K
	o.M(9)
catch
	? "[" + cCatchError + "]"
done
? "still running"
class K
	def M(n)
		y = [1]
		return y[n]
