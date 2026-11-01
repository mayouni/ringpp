# Calls a function no file has defined yet: R3 when it runs, as on Ring.
? "r02: " + Bump() + " " + Bump()
try
	? Later(1)
catch
	? "r02: " + cCatchError
done

func CallsLater x
	return Later(x) + 1

func CallsLater2
	return Later2(1, 2)

func ReadsQ9
	return q9
