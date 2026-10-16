# A builtin handed the wrong TYPE raises on Ring; it must never panic here.
# del() and insert() with a position that is not a number -- a numeric
# string included -- and the maths family (sqrt, floor, ceil, sin, exp,
# log, fabs, pow) with a string or a list: "Bad parameter type!",
# catchable, on both 1.27 builds (2026-09-30). del() and every one of the
# maths builtins but fabs PANICKED in asInt/asF64, which no try can catch:
# Softanza's semantic resolver probes stzNumber's methods inside a try,
# and MostSquareLikeFactors() hands sqrt() a number's string content --
# eight tests died there once a cache invalidation made it probe again.
aL = [10, 20, 30]
try  del(aL, "2")   ? "del string-number: " + len(aL)   catch  ? "del '2' : " + cCatchError  done
try  del(aL, "a")   ? "del string: " + len(aL)          catch  ? "del 'a' : " + cCatchError  done
try  del(aL, [1])   catch  ? "del list: " + cCatchError  done
try  insert(aL, "1", 5)   ? "insert string-number: " + len(aL)   catch  ? "insert '1': " + cCatchError  done
try  insert(aL, "x", 5)   catch  ? "insert 'x': " + cCatchError  done
try  insert(aL, [1], 5)   catch  ? "insert list: " + cCatchError  done
? "done " + len(aL)
for f in [ "sqrt", "floor", "ceil", "sin", "exp", "log", "fabs" ]
	for a in [ "16", "abc", "" ]
		try
			v = 0
			eval("v = " + f + '("' + a + '")')
			? f + '("' + a + '") = ' + v
		catch
			? f + '("' + a + '") : ' + cCatchError
		done
	next
next
try  ? "pow('2', 3) = " + pow("2", 3)  catch  ? "pow('2',3) : " + cCatchError  done
try  ? "sqrt([4]) = " + sqrt([4])     catch  ? "sqrt([4]) : " + cCatchError  done
