# Ring's `%` is C's fmod on two doubles: a real divisor is not truncated,
# the answer takes the dividend's sign, and `%=` is the same operator.
decimals(4)
? 2.07 % 0.39
? 5.5 % 2
? 7 % 2.5
? -7 % 3
? 7 % -3
? -7.5 % 2
? 0.5 % 0.2
? 10 % 3
? "7" % 2.5
x = 2.07  x %= 0.39  ? x
n = 17  n %= 5  ? n
aL = [10, 7.5]  aL[2] %= 2  ? aL[2]
try ? 5 % 0 catch ? cCatchError done
try ? 5 % 0.0 catch ? cCatchError done
try ? 5 % 0.4 catch ? cCatchError done
try ? 5 % "abc" catch ? cCatchError done
try ? [1] % 2 catch ? cCatchError done
try ? "7" % 2 catch ? cCatchError done
try ? "x" % 2 catch ? cCatchError done
s = "9"  ? s % 4
? Gcd(2.07, 0.39)
? Gcd(12, 18)

func Gcd a, b
	while b != 0
		t = b
		b = a % b
		a = t
	end
	return a
