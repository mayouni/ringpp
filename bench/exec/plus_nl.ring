# A NUMBER PLUS NL IS TEXT -- 2026-10-05.
#
# Ring's `+` with a number on the left and a string on the right converts the
# string and ADDS -- except when the string is exactly the newline: then the
# answer is the number's text with the newline after it (ring_vm_sum,
# vendor/ring-vm/src/vmexpr.c:27, "string/number + nl ---> string"). Softanza
# writes `? RandomNumberBetween(100, 150) + NL` and its kind across the test
# suite; Ring++ converted "\n", found no number in it, and raised R41.
#
# Only the newline ALONE: a space, a tab, "3\n" or " \n" are converted as
# before -- numeric is added, the rest is R41. And only `+`: `y += nl` is
# R41 on both builds (row 6), the second time `+` and `+=` part (F-51).
# Every row is the oracle's answer and official 1.27's.

x = 5 + nl
? "1 [" + x + "] " + type(x) + " " + len(x)
x = 2.5 + nl
? "2 [" + x + "] " + type(x) + " " + len(x)
x = 5 + "3"
? "3 [" + x + "] " + type(x)
x = 5 + " 3"
? "4 [" + x + "] " + type(x)
x = 5 + char(10)
? "5 [" + x + "] " + type(x)
try
	y = 7
	y += nl
	? "6 [" + y + "] " + type(y)
catch
	? "6 " + cCatchError
done
try
	x = 5 + " "
	? "7 [" + x + "]"
catch
	? "7 " + cCatchError
done
try
	x = 5 + char(9)
	? "8 [" + x + "]"
catch
	? "8 " + cCatchError
done
try
	x = 5 + ("3" + nl)
	? "9 [" + x + "]"
catch
	? "9 " + cCatchError
done
try
	x = 5 + (" " + nl)
	? "10 [" + x + "]"
catch
	? "10 " + cCatchError
done
try
	x = 5 - nl
	? "11 [" + x + "]"
catch
	? "11 " + cCatchError
done
z = Twice(4) + nl
? "12 [" + z + "] " + type(z)
? "13 [" + (10 / 4 + nl) + "]"

func Twice n
	return n * 2
