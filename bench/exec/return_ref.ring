# RING COPIES AT THE ASSIGNMENT, NEVER AT THE RETURN.
#
# C-7 recorded, on 2026-09-10, that a list or an object is copied at "a
# method's `return`". The probe that measured it did `r = o.GetL()` -- an
# ASSIGNMENT -- so the copy it saw was the assignment's and the return was
# never isolated. This file isolates it: the returned object is used as a
# RECEIVER, with no assignment anywhere, and on Ring the mutation lands on
# the original.
#
# WHAT IT COST THE ESTATE. Softanza's node plane is a singleton reached only
# through its accessor: `StzNodePlane().Register(...)`, `StzNodePlane().Ask(
# ...)`, `StzNodePlane().LastStatus()`. With a copy at the return, each of
# those acted on a fresh throwaway: the name registered was never found, the
# Ask answered "" with the status untouched at its initial :Ok, and every
# liveness check in cluster/d3_supervision was a false pass -- so its drive
# loops burnt their full budgets and the test ran past the harness's 120 s.
# That was the last "hang" in the wide clock.
#
# The rule that stays: `x = P()` COPIES, because that is an assignment.
# Both halves are here, and both are what the oracle prints.

$o = ""
$nCreated = 0

? "-- through the accessor, no assignment: the ORIGINAL is mutated --"
P().Bump()
P().Bump()
P().Bump()
? "  created " + $nCreated + " time(s)"
? "  P().N() = " + P().N()
? "  $o.N()  = " + $o.N()

? ""
? "-- a method returning This, used as a receiver: the original again --"
$o.Me().Bump()
? "  $o.N()  = " + $o.N()

? ""
? "-- but ASSIGNED, the result is a COPY: the original stays --"
x = P()
x.Bump()
x.Bump()
? "  x.N()   = " + x.N()
? "  $o.N()  = " + $o.N()

? ""
? "-- and a returned attribute LIST, the same two ways --"
# (A call's result as a MUTABLE TARGET -- `q.L()[1] = 99`, or
#  `add(q.L(), 99)` -- is a shape Ring++ refuses at compile time today;
#  that is its own item. Passed as a PARAMETER it is the same reference,
#  by reference under C-7, and that compiles.)
q = new H
zzAppend(q.L(), 99)
? "  len(q.L()) after add() through the returned reference = " + len(q.L())
aL = q.L()
add(aL, 7)
? "  len(q.L()) after add() to an assigned copy            = " + len(q.L())
? "  len(aL)    for the copy itself                        = " + len(aL)

? ""
? "done"

func zzAppend aL, v
    add(aL, v)

func P()
    if $o = ''
        $nCreated++
        $o = new K
    ok
    return $o

class K
    @n = 0
    def Bump()
        @n++
    def N()
        return @n
    def Me()
        return This

class H
    @l = [1, 2]
    def L()
        return @l
