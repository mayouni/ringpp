# `:Name = value` is a NAMED PARAMETER on Ring -- the two-element list
# ["name", value] -- and not a comparison. F-59, measured on 1.27.
#
# Every row below was taken from the oracle before a line of Ring++ changed.
# The last two are the ones that fix the RULE: it is the SYMBOL on the left
# that makes the pair, not the shape of the line. A string or a variable on
# the left is still an ordinary equality.
#
# Ring++ compiled all of them as equalities, so every named argument in
# Softanza -- about a thousand sites -- arrived as 0. Silently: the callee's
# `isList()` guard is then false, its unwrapping never runs, and the value it
# uses is a number nobody passed. StzListParserQ().Parse ended up at
# `for i = 3 to 9 step 0`, a loop that appends for ever, which was the last
# `panic: oom` in the wide clock.
#
# THE OTHER HALF OF THE FIX IS THE TYPE TABLE, and it cost far more than the
# rule. `exprClass` still called this a comparison, so the register holding
# the pair was not marked as holding a REFERENCE: nobody balanced the
# callee's release, the pair was freed while still in use, and an ordinary
# `if isList(a) and (f(a) or g(a))` segfaulted at 0xc. The POISONING HEAP
# named it -- with freed memory never reused, the same program passed.
# `exprClass` carries a paragraph about exactly this trap under `+`, from
# 2026-09-03. A rule and the class that describes it are one change.

? "-- a pair, wherever a value is wanted --"
? "  in a call         : " + zzShow(zzArg( :From = 3 ))
? "  the value is EVALUATED: " + zzShow(zzArg( :From = 1 + 2 ))
? "  assigned          : " + zzShow(( :To = 9 ))
aL = [ :Step = 3 ]
? "  inside a list     : " + zzShow(aL[1])

? ""
? "-- and it is TRUE in a condition, because a list is truthy --"
if :From = 3
    ? "  the then branch"
else
    ? "  the else branch"
ok

? ""
? "-- but the rule is the SYMBOL, not the shape --"
? "  a string on the left  : " + zzShow(zzArg( "from" = 3 ))
x = 5
? "  a variable on the left: " + zzShow(zzArg( x = 3 ))
? "  a bare symbol         : " + zzShow(zzArg( :From ))

? ""
? "-- several in one call, which is how the estate writes them --"
zzThree( :From = 3, :To = 9, :Step = 3 )

? ""
? "done"

func zzArg p
    return p

func zzThree a, b, c
    ? "  three pairs       : " + zzShow(a) + " " + zzShow(b) + " " + zzShow(c)
    if isList(a) and ( zzIsFrom(a) or zzIsTo(a) )
        ? "  and a guard over them reads them back: " + a[2] + " " + b[2] + " " + c[2]
    ok

func zzIsFrom aL
    if NOT isList(aL) return 0 ok
    if len(aL) != 2 return 0 ok
    return aL[1] = :From

func zzIsTo aL
    if NOT isList(aL) return 0 ok
    if len(aL) != 2 return 0 ok
    return aL[1] = :To

func zzShow v
    if isList(v)
        cR = "["
        for i = 1 to len(v)  cR += "" + v[i] + " "  next
        return cR + "]"
    ok
    return type(v) + " " + v
