# Reading a top-level name that was never assigned is Ring's R24, raised
# AT THE READ and naming the variable folded to lower case -- probed on
# 1.27, where `? NOTSET` alone is enough; no operator has to see the value.
#
# Ring++ used to refuse the statement at compile time, which poisoned the
# whole top level and printed NOTHING. reactive/62_reactive_timer_surface
# produced 0 lines where Ring produced 11 and then its error, because the
# test reads `HOUR` where the library defines `$HOUR` (2026-09-12).
#
# `$HOUR` and `HOUR` are DIFFERENT variables on Ring -- probed, both
# builds -- so the two names below must not resolve to one another.

$WITHDOLLAR = 3600000

? "assigned with the dollar : " + $WITHDOLLAR
? "the lines before it run  : yes"
? "now the bare one, never assigned anywhere:"
? 5 * WITHDOLLAR
? "NOT REACHED -- Ring stops at the line above"
