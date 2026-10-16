load "b.ring"
fA = func t { return "A" + t }
fAB = func t { return call fB(t) + "+" }
nADone = 1
