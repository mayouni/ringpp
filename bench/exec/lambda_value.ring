# What a LAMBDA VALUE is to the type predicates, measured on 1.27: it is a
# STRING naming a generated function, so type() says STRING, isString 1,
# isList 0, and isFunction 1 -- which is how Softanza guards a callback:
# `isString(f) and isFunction(f)` (StzReactiveObjectQ().Watch and Computed).
# Ring++ keeps a closure as a vector for `call`, flagged at birth, and
# answers these four as Ring does. isfunction on a number or a list is
# "Bad parameter type!" on both.

f = func { return 1 }
? "1 type " + type(f)
? "2 isfunction(f) " + isfunction(f)
? "3 isstring " + isstring(f)
? "4 islist " + islist(f)
? "5 isfunction(name) " + isfunction("G")
? "6 isfunction(missing) " + isfunction("nosuch")
? "7 isfunction(builtin) " + isfunction("len")
g = func x { return x + 1 }
? "8 " + call g(41)
h = g
? "9 a copy: " + type(h) + " " + isfunction(h) + " " + call h(1)
? "10 ismethod(o, M) " + ismethod(new K, "M")
? "11 ismethod(o, missing) " + ismethod(new K, "Z")
try
	? "12 isfunction(5) " + isfunction(5)
catch
	? "12 " + cCatchError
done
try
	? "13 isfunction([1]) " + isfunction([1])
catch
	? "13 " + cCatchError
done
aBig = [1790000000, 1790000001]
? "14 a list of epoch seconds: " + type(aBig) + " " + islist(aBig) + " " + isstring(aBig)

func G
	return 2

class K
	def M
		return 1
