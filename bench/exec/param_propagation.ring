# A WIDENED PARAMETER HAS TO REACH ITS CALLEES.
#
# The compiler proves which locals can hold a reference by iterating to a
# fixpoint, and `promoteCallArgs` is part of that: the class of an ARGUMENT
# at a call site is joined into the callee's PARAMETER. Separately, a
# parameter no observed call site can speak for is widened to a reference,
# because assuming integer there would be a guess.
#
# That widening ran AFTER the fixpoint, so its results never propagated.
#
#   `a++` below proves Take's `a` an integer.
#   The fixpoint carries that integer into zzShow's `v`.
#   The widening then raises Take's `a` to a reference -- methods have no
#   observed call site -- and leaves zzShow's `v` an integer behind it.
#
# So zzShow copied the list with `move c=0`, retaining nothing, into a
# register its own frame mask releases at `ret`. One release too many, on
# every call, and the list the caller still held was freed under it.
#
#   ReleaseSafe    panic: integer overflow in release, or `switch on
#                  corrupt value` in freeVec once the memory was reused
#   ReleaseFast    nothing at all: correct output, `done` printed, and
#                  then the process spins for ever inside exit
#
# THE `if` IS REQUIRED and so is the `a++`. Remove either and the register
# allocation changes enough that the unretained copy is never made. Five
# smaller reproductions built from scratch all missed it; this one was
# reached by cutting a real failure down.
#
# The fix is one word of placement: widen at round 0 of the fixpoint rather
# than after it, so the rounds that follow carry it into the callees.
#
# IT IS THE `s[i]` DEFECT OF 2026-09-19 FROM THE OTHER END -- a register in
# the frame mask holding a value nobody retained. That one came from a rule
# changing under its type table; this one from a type table updated too
# late to propagate. Same corruption, same sweep, opposite causes.

p = new zzHolder
p.Take( ["a", 1], ["b", 2] )

? ""
? "done"

func zzShow cTag, v
    if isList(v)
        cR = "  " + cTag + " len=" + len(v)
        cR += " [1]=<" + v[1] + ">"
        ? cR
    ok

class zzHolder

    def Take(a, b)
        zzShow("a", a)
        zzShow("b", b)
        # never taken on a list, and it is still what proves `a` an integer
        if isNumber(a)
            a++
        ok
