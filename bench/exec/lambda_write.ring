# C-14: A TOP-LEVEL LAMBDA'S BARE WRITE REACHES THE TOP LEVEL'S GLOBAL --
# the lambda's names are its DEFINING scope's names, and at the top level
# those are globals, as on Ring. Its free READ of the name was already the
# global (2026-09-22); the write follows. reactivehttp/01_http_setters
# collects its error through `func e { cWhy = "" + e }`; five reactive
# tests died on `nFires++` and `gGot = "" + v` in such lambdas. A lambda's
# own parameter and a name assigned nowhere at the top level are the
# lambda's own; a named FUNCTION's bare write stays local (C-2).

cWhy = "(never)"
f = func e { cWhy = "why: " + e }
call f("boom")
? "1 " + cWhy
nFires = 0
g = func { nFires++ }
call g()
call g()
? "2 " + nFires
nTotal = 10
h = func v { nTotal += v }
call h(5)
? "3 " + nTotal
aSeen = []
k = func x { aSeen + x }
call k("a")
call k("b")
? "4 " + len(aSeen)
m = func cWhy { cWhy = "shadowed"  return cWhy }
? "5 " + call m("p") + " / " + cWhy
