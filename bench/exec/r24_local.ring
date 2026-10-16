# F-89. A LOCAL read on a path where nothing has assigned it is R24 on
# Ring, naming it, the moment the read runs -- catchable. Ring++ checked
# globals and attributes at the read, never a local: a local whose other
# assignment sat in a branch not taken read nil and ran on. The estate's
# largest remaining line class was this shape -- stzList.operator() tests
# `$_bTheseQ` and then re-reads a bare `_bTheseQ` it only resets inside
# another branch, left behind by the Rule A migration of 2026-09-01.

? "if, taken       : " + zzTry("A", 1)
? "if, not taken   : " + zzTry("A", 0)
? "if/else         : " + zzTry("B", 0)
? "for, ran        : " + zzTry("C", 2)
? "for, never ran  : " + zzTry("C", 0)
? "switch, hit     : " + zzTry("D", 2)
? "switch, miss    : " + zzTry("D", 3)
? "early return    : " + zzTry("F", 0)
? "flag, set path  : " + zzTry("H", 1)
? "flag, read path : " + zzTry("H", 0)
? "while, ran      : " + zzTry("W", 2)
? "while, not ran  : " + zzTry("W", 0)
? "catch var       : " + zzTry("T", 0)
? "done"

func zzTry(cF, p)
	try
		switch cF
		on "A"  return A(p)
		on "B"  return B(p)
		on "C"  return C(p)
		on "D"  return D(p)
		on "F"  return F(p)
		on "H"  return H(p)
		on "W"  return W(p)
		on "T"  return T(p)
		off
	catch
		return cCatchError
	done

func A(p)
	if p
		x = 1
	ok
	return x

func B(p)
	if p
		y = 1
	else
		y = 2
	ok
	return y

func C(p)
	for i = 1 to p
		z = i
	next
	return z

func D(p)
	switch p
	on 1  w = "one"
	on 2  w = "two"
	off
	return w

func F(p)
	if p
		return "early"
	ok
	q = 5
	return q

func H(p)
	if p
		_bFlag = 0
		return "set"
	but _bFlag
		return "read"
	ok
	return "none"

func W(p)
	n = p
	while n > 0
		u = n
		n--
	end
	return u

func T(p)
	try
		raise("boom")
		v = 1
	catch
		return "caught, then " + v
	done
	return "unreached"
