# F-122. Two lambda values are equal when they name one function. On Ring a
# lambda IS the string of its generated name, so `f3 = f1` then `f1 = f3` is
# 1, find() finds it, and two different `func { }` are never equal. A lambda
# here is the vector [id + bias, captures...] and the assignment copies it,
# so the identity test answered 0 for all of them. Softanza depends on it:
# StzGraphQ()._GetFunctionName names a rule's function by comparing it with
# DerivationFunc_Transitivity() and its siblings, and answered
# "CustomFunction" for every built-in rule. Measured on both 1.27 builds
# 2026-10-14, every row the same on both.

f1 = func { return 1 }
f2 = func { return 1 }
f3 = f1
? "1 f1 = f3: " + (f1 = f3)
? "2 f1 = f2: " + (f1 = f2)
? "3 f1 != f2: " + (f1 != f2)
? "4 f1 != f3: " + (f1 != f3)
aL = [f2, f1]
? "5 find(aL, f1): " + find(aL, f1)
? "6 f1 = 1: " + (f1 = 1)
? "7 f1 = '': " + (f1 = "")
if f1 = f3 ? "8 if f1 = f3 taken" ok
n = 5
g1 = func x { return x + n }
g2 = g1
? "9 g1 = g2: " + (g1 = g2)
? "10 call g2(1): " + call g2(1)
? "11 type(f1): " + type(f1) + " len>0: " + (len(f1) > 0)
? "12 f1 = [1]: " + (f1 = [1])
? "13 Maker() = Maker(): " + (Maker() = Maker())
? "14 Maker() = f1: " + (Maker() = f1)

func Maker
	return func x { return x * 2 }
