# `a : b`, every shape Ring 1.27 answers consistently (measured 2026-09-10
# on both builds). Found because Softanza's stzCharData.ring:884 says
# `$_acDecimalchars = "0" : "9"` at load, and the VM read the range as
# integers only: a string operand was a panic, and `5:1` was empty where
# Ring counts down. The shapes Ring answers INCONSISTENTLY ("ab":"cd",
# "abc":"z", "x":5) are not here on purpose -- Ring++ raises on them, a
# decision recorded as C-5, and a probe compared to the oracle cannot hold
# a decided divergence.
a = "0" : "9"
? "A " + len(a) + " " + a[1] + " " + a[10] + " " + type(a[1])
b = "a" : "e"
? "B " + len(b) + " " + b[3]
c = "e" : "a"
? "C " + len(c) + " " + c[1] + c[5]
d = "A" : "z"
? "D " + len(d) + " " + d[2]
k = 5 : 1
? "K " + len(k) + " " + k[1] + " " + k[5]
l = 1 : 1
? "L " + len(l) + " " + l[1]
m = 1.5 : 3.5
? "M " + len(m) + " " + m[1] + " " + m[len(m)]
n = 3 : 1.5
? "N " + len(n) + " " + n[1] + " " + n[len(n)]
o = -2 : 1
? "O " + len(o) + " " + o[1]
f = 2.7 : 5
? "F " + len(f) + " " + f[1] + " " + f[len(f)]
h = 1 : 5
? "H " + len(h) + " " + type(h[1])
try e = 1 : "5" ? "E " + len(e) catch ? "E err " + cCatchError done
