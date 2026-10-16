# A `for` WHOSE VARIABLE IS AN ATTRIBUTE drives the attribute.
#
# On Ring the sigil is just a character, so `for @i = 1 to 3` in a method
# loops a method-local named `@i`, and the body's `@i` is that variable.
# Under Rule A `@i` is the attribute -- so the attribute is what the loop
# writes, at the top of every iteration, the way a `$` loop variable
# already wrote its global. The body reads the slot and sees the counter.
#
# Before: the counter lived in a LOCAL named "@i" while every read in the
# body went to the attribute slot the loop never touched -- so
# stzRegex.CaptureGroups() passed nil to the engine on every iteration and
# three linguistic tests failed their assertions, silently, until gattr
# began raising R24 on a nil slot and they stopped on line 852 instead.
#
# The rows: the sum the body accumulates, the variable after the loop
# (n+1 on Ring, as for any counter), a nested body reading it, and a
# second method seeing the value the first one left -- which on Ring is a
# fresh local and R24. That last row is the one Rule A DECIDES differently
# and is left out; the attribute keeps its last value here, by design.

o = new zzR
? "-- the body reads the counter --"
? "  " + o.Sum(4)
? ""
? "-- after the loop, in the same method --"
? "  " + o.After(3)
? ""
? "-- a nested loop over two attributes --"
? "  " + o.Grid()
? ""
? "-- with a step --"
? "  " + o.Stepped()
? ""
? "-- a $global loop variable: after the loop, and after an exit --"
for $g = 1 to 3
next
? "  $g after `for $g = 1 to 3` = " + $g
for $g = 1 to 9
    if $g = 5  exit  ok
next
? "  $g after an exit at 5      = " + $g
? ""
? "done"

class zzR
    @i = 0
    @j = 0
    def Sum(n)
        acc = 0
        for @i = 1 to n
            acc += @i
        next
        return "sum 1.." + n + " = " + acc
    def After(n)
        for @i = 1 to n
        next
        return "@i after `for @i = 1 to " + n + "` = " + @i
    def Grid()
        cR = ""
        for @i = 1 to 2
            for @j = 1 to 3
                cR += "" + @i + @j + " "
            next
        next
        return cR
    def Stepped()
        cR = ""
        for @i = 10 to 1 step -3
            cR += "" + @i + " "
        next
        return cR
