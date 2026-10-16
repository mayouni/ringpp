# A METHOD'S PARAMETER CANNOT BE TYPED FROM ITS OWN BODY.
#
# Inference proves a local is an integer and clears its register from the
# frame mask, so it carries no retain and no release. That is sound for a
# local, whose every value the body assigns. It is NOT sound for a
# parameter: the first value comes from the caller, and nothing in the body
# can say what that is.
#
# Methods had it backwards. `called` has one reader -- the rule that widens
# a parameter to a reference when no call site was observed -- and a method
# was born with `called = true`, so the rule skipped it. Nothing ever set
# it either: promoteCallArgs resolves plain names through findFunc, which
# skips every method. So a method's parameters were typed from assignments
# in its own body alone.
#
# ONE LINE IN A BRANCH THAT NEVER RUNS is enough, and it is below:
#
#     if pnEnd = :Last
#         pnEnd = len(@aList)     <- proves pnEnd an integer
#     ok
#
# The list the caller passed is then never retained, the frame sweep frees
# it with the caller still holding it, and the string inside comes back as
# pointer-shaped bytes. Only the LAST argument survives, because only its
# register has not yet been reused -- and that asymmetry is what named the
# defect. stzListParser.Parse is where it was found; on the build before
# the fix this probe prints `end len=2 [1]=<?=?U >` and then hangs.
#
# EVERY LINE OF THE READER IS LOad-BEARING, and each was verified by
# putting the defect back:
#
#   the CHURN -- on a quiet heap the freed bytes are still intact and a
#       broken build passes. Something has to claim them.
#   the LOOP, the IN-PLACE APPEND and the v[i] reads -- a plain
#       `? v[1]` reader passes on the broken build. It never disturbs
#       the freed memory.
#   the `if isList(v)` around them -- without it, the broken build
#       prints every key correctly. Removing it was tried, and the probe
#       stopped being a guard.
#
# WHAT IS DELIBERATELY ABSENT is `a++` on a method parameter. That, with a
# reader of this shape, tripped a SECOND defect -- the widening ran AFTER
# the classification fixpoint, so it never reached the callees a widened
# parameter is passed to. Fixed the day after this one, and pinned by
# `bench/exec/param_propagation.ring`, which is its own file for a reason: a
# probe that pins two defects at once tells you neither.

o = new zzParser
o.Parse( ["from", 3], ["to", 9], ["step", 3] )

? ""
? "done"

func zzChurn
    aL = []
    for i = 1 to 400
        aL + ("" + i + "-filler-filler-filler")
    next
    return len(aL)

func zzShow cTag, v
    if isList(v)
        cR = "  " + cTag + " len=" + len(v)
        for i = 1 to len(v)
            cR += " [" + i + "]=<" + v[i] + ">"
        next
        ? cR
    else
        ? "  " + cTag + " not a list: <" + v + ">"
    ok

class zzParser

    @aList = [ "A", "B", "C" ]

    def init()
        This.Parse(1, 3, 1)

    def Parse(pnStart, pnEnd, pnStep)
        nJunk = zzChurn()
        zzShow("start", pnStart)
        zzShow("end  ", pnEnd)
        zzShow("step ", pnStep)
        # never taken here, and that was the whole point
        if pnEnd = :Last
            pnEnd = len(@aList)
        ok
