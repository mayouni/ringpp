# F-87. A call to a name nothing defines is looked up when the call STARTS,
# as Ring's LOADFUNC does: R3 comes BEFORE any argument is evaluated -- no
# "evaluated" line prints, on either 1.27 build -- and the report gives the
# line of the NAME, not the line the arguments close on. Ring++ evaluated
# the arguments first and reported the closing line; on Linux six http
# tests stop at a missing engine domain and differed on that line alone.
# Uncaught at the end on purpose, so the trace prints.
try
	zzNope(zzSay("arg one"),
		zzSay("arg two"))
catch
	? "caught: " + cCatchError
done
try
	x = 1 + zzNope2(zzSay("in a sum"))
catch
	? "caught: " + cCatchError
done
zzGo()

func zzGo
	x = zzNope3(1,
		zzSay("three"),
		3)

func zzSay s
	? "evaluated " + s
	return s
