fB = func t { return "B" + t }
fBB = func t { return call fB(t) + call fB(t) }
