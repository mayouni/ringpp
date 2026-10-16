# RING'S NUMBERS ARE DOUBLES, and an integer past 2^53 is the DOUBLE Ring
# computes. Measured on both 1.27 builds. Ring++ keeps an integer while it is
# exact, within +/-(2^53-1) -- the range Ring itself prints as an integer
# (ring.h:120) -- and computed past it in 64-bit integers, so a 32-bit LCG in
# plain Ring arithmetic (row 9, the shape numeric_embedding makes its data
# with) gave a different sequence, and seventy doublings wrapped to -1. A
# whole double past the range prints through "%.Nf" on Ring: its exact
# expansion, and under decimals(2) two zeros after the point (row 15).

decimals(0)
a = 2147483647
b = 1103515245
p = a * b
? "1 a*b: " + p
q = p + 12345
? "2 a*b + 12345: " + q
? "3 (a*b+12345) % 2147483648: " + (q % 2147483648)
n = 9007199254740992
? "4 2^53 + 1: " + (n + 1)
? "5 2^53 + 2: " + (n + 2)
? "6 2^53 - 1: " + (n - 1)
x = 10000000000
? "7 1e10 * 1e10: " + (x * x)
y = 3037000499
? "8 3037000499^2: " + (y * y)
nS = 20260727
s = ""
for i = 1 to 6
	nS = (nS * 1103515245 + 12345) % 2147483648
	s += "" + nS + " "
next
? "9 the test's LCG: " + s
m = 9007199254740993
? "10 a literal above 2^53: " + m
k = 4611686018427387904
? "11 2^62 + 2^62: " + (k + k)
? "12 -2^53 - 1: " + (-n - 1)
z = 0
for i = 1 to 70
	z = z * 2 + 1
next
? "13 doubling 70 times: " + z
? "14 type: " + type(p) + " isnumber " + isnumber(p)
? p
? "16 1e15 exactly: " + (1000000 * 1000000000)
w = 9007199254740991
? "17 2^53-1 stays an integer: " + w + " and + 0: " + (w + 0)
? "18 2^53 - 1 + 1: " + (w + 1)
decimals(2)
? "15 a*b with decimals 2: " + p
? "19 under decimals 2, 2^53: " + (w + 1) + " and 1e15: " + (1000000 * 1000000000)
