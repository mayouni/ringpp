# F-102, the compiler's half: add() is a `vpush`, which also builds list
# literals and `aL[i] + v`, so only the compiler can say which one is add()
# -- it marks it, and the report reads `In add() In function f()` as Ring's.
# A caught one first: a caught error shows no frames at all.
try
	add(5, 1)
catch
	? "caught: " + cCatchError
done
f()

func f
	x = [1, 2]
	add(x, 3)
	? len(x)
	add(7, 1)
