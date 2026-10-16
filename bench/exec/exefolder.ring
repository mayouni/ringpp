# exefolder() ends with the path separator on Ring; currentdir() does not
# (measured 2026-09-10 on both builds). rnx returned exefolder() without it,
# and the estate spells every path from it as `exefolder() + "x"` -- the 80
# engine-discovery warnings differed between the oracle and rnx by exactly
# that character. The folders themselves differ per machine, so only the
# last character is compared.
? "exefolder ends with [" + right(exefolder(), 1) + "]"
? "currentdir ends with sep: " + (right(currentdir(), 1) = "\")
