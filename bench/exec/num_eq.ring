# Equality on NUMBERS, probed on Ring 1.27.
#
# Ring has one number type -- a double -- and compares by VALUE, not by how
# the value is stored: `2.0 = 2` is true, and a numeric STRING equals its
# number in both directions.
#
# valEq had cases for int, string, list and object and NO case for a float,
# so it fell through to false: `1.5 = 1.5` was false, `if x = 1.5` took the
# else branch, and `!=` on two equal floats answered TRUE. Every module in
# the A/B suite compares integers, which is why it survived until
# 2026-09-12, when perf/tracing_tail asked `aT[1][:durMs] = 1.5` about a
# value that printed as 1.50.
#
# Line 12 is NOT a bug on either side: 0.1 + 0.2 is not 0.3 in IEEE, and
# both runtimes say so. That is C-1, kept.
? "01 1.5 = 1.5      " + (1.5 = 1.5)
? "02 1.5 = 1.6      " + (1.5 = 1.6)
? "03 1.5 = 1        " + (1.5 = 1)
? "04 2.0 = 2        " + (2.0 = 2)
? "05 2 = 2.0        " + (2 = 2.0)
? "06 4/2 = 2        " + (4/2 = 2)
? "07 1.5 = '1.5'    " + (1.5 = "1.5")
? "08 '1.5' = 1.5    " + ("1.5" = 1.5)
? "09 1.5 = 'abc'    " + (1.5 = "abc")
? "10 1.5 != 1.6     " + (1.5 != 1.6)
? "11 1.5 != 1.5     " + (1.5 != 1.5)
? "12 0.1+0.2 = 0.3  " + (0.1 + 0.2 = 0.3)
? "13 1.5 = NULL     " + (1.5 = NULL)
? "14 2.0 = '2'      " + (2.0 = "2")
n = 3.25
m = 3.25
? "15 n = m          " + (n = m)
? "16 n = 3.25       " + (n = 3.25)
