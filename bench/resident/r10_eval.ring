# The program after all of it: eval reaches an admitted function, the
# globals kept their values, an object made by the first file still answers
# and a new one can be made, and a refused file's names are absent.
eval("? 'r10: ' + Later(7)")
? "r10: " + Bump() + " " + Twice(5)
? "r10: " + $oTally.Plus(10) + " " + (new Tally).Plus(1)
try
	? ReadsQ9()
catch
	? "r10: " + cCatchError
done
? "r10: " + isFunction("good04") + " " + isFunction("callslater")
