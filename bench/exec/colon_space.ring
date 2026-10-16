# A bare colon, then a space, then a word: Ring reads the WORD as a symbol and drops the space (the analysis's 2.14 calls the
# construct a hazard; Ring++ keeps Ring's answer). Ring++ kept the space until 2026-10-15, so `x = : word` was " word" -- found by
# the site's issue probes. Every row taken from official Ring 1.27 and the oracle first.
a = : word
? "[" + a + "]"
b = :   word
? "[" + b + "]"
c = :	tabbed
? "[" + c + "]"
d = : Mixed
? "[" + d + "]"
e = :tight
? "[" + e + "]"
? len(a)
