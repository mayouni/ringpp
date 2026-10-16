# `cCatchError` OUTSIDE a catch body, measured on 1.27: it is a process-wide
# variable -- the string "NULL" before any catch has run, then the last
# caught message, readable from ANY function until the next catch overwrites
# it. Softanza reads it that way: `CatchError()` in stkRingFuncs.ring is a
# function called from inside handlers, and Ring++ refused the read until
# 2026-09-24 (C-15). Inside a catch body it stays the handler's own binding;
# the one row where that differs from Ring -- a callee's catch overwriting
# the error its caller is handling -- is recorded under C-15 and is not here.

try
	? "1 before any catch: [" + cCatchError + "]"
catch
	? "1 raised: " + cCatchError
done
? "2 outside, after a catch that never ran: [" + CE() + "]"
try
	raise("boom")
catch
	? "3 in catch: " + cCatchError
	? "4 via function inside catch: " + CE()
done
? "5 outside, after boom: [" + CE() + "]"
? "6 top level, after boom: [" + cCatchError + "]"
try
	x = 1 / 0
catch
	? "7 " + cCatchError
done
? "8 " + CE()
? "9 in a plain function: " + Deep()

func CE
	return cCatchError

func Deep
	return "[" + cCatchError + "]"
