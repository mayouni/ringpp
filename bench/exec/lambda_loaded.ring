load "lambda_loaded_lib/a.ring"
fR = func t { return "R" + t }
? "1 " + call fA("x")
? "2 " + call fAB("y")
? "3 " + call fB("z")
? "4 " + call fBB("w")
? "5 " + call fR("v")
? "6 " + nADone

#
# A LAMBDA AT THE TOP LEVEL OF A LOADED FILE -- 2026-10-05. A file's top-level statements are appended to `@@main`, which the FIRST file that has one creates, and the
# pass that lowers lambdas walked only the functions a file added -- so a lambda at the top level of any later file (here a.ring, and b.ring which a.ring loads) was never
# lowered, and its statement was refused ("lambda was not lowered") while the same line in the root worked. Lambdas inside functions were never affected, which is why
# nothing in Softanza showed it. Every row is the oracle's answer and official 1.27's.
