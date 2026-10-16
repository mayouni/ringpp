# `call f(x) = v` and `call f(x) + 1`, measured on 1.27: the keyword binds
# the CALL, and the operator applies to its answer -- a comparison yields
# 1 or 0, an arithmetic its value. The grammar hands Ring++ the keyword
# over a binary whose left side is the call, and it refused the shape
# until 2026-09-24; stzRefinableCode's `if call _f_(This) = 0` is that.

f = func x { return x * 2 }
if call f(3) = 6 ? "1 call f(3) = 6 holds" else ? "1 no" ok
if call f(3) = 0 ? "2 no" else ? "2 call f(3) = 0 does not hold" ok
? "3 " + (call f(4) + 1)
x = call f(5) = 10
? "4 x is " + x
g = func { return "" }
if call g() = "" ? "5 empty" else ? "5 no" ok
? "6 " + (call f(2) * 10)
if call f(1) < 3 ? "7 less" else ? "7 no" ok
if call f(1) != 2 ? "8 no" else ? "8 equal" ok
