# floor(a / b) is the integer-division idiom ONLY when both sides are whole
# (F-129). Real operands were truncated before dividing: the first row read 14.
pw = 612
lf = log10(100)
lt = log10(8000)
hz = 18 * 5.859375
? "spectrum pixel  " + floor(pw * (log10(hz) - lf) / (lt - lf))
x = 14.15  y = 1.9
? "reals           " + floor(x / y)
a = 7  b = 2.5
? "int by real     " + floor(a / b)
? "whole           " + floor(7 / 2) + " " + floor(-7 / 2) + " " + floor(10 / 4) + " " + floor(9.0 / 3)
n = 17  d = 5
? "int locals      " + floor(n / d) + " " + floor(-n / d)
s = "9"
? "numeric string  " + floor(s / 2)
try
	? floor(5 / 0)
catch
	? "int by zero     " + cCatchError
done
try
	z = 0.0
	? floor(5.5 / z)
catch
	? "real by zero    " + cCatchError
done
