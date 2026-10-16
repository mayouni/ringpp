# A READ OF A VARIABLE NOTHING HAS ASSIGNED IS R24, AT THE READ.
#
# Every row below was taken from Ring 1.27 first. The error is raised the
# moment the variable is READ -- alone, in a comparison, as a subscript, in
# a concatenation, as an argument -- it is CATCHABLE, and it NAMES the
# variable folded to lower case with its sigil: `$zzneverset`, `@nunset`.
#
# Ring++ let the nil through to whatever operator met it later. A
# comparison passed silently, a subscript said "Bad parameter type!", and
# the R24 the operators did raise carried no name -- so no line ever
# matched Ring's. That was a six-test cause class in the wide clock, and
# it was the line cluster/d3_supervision stops on: Ring's `Error (R24) :
# Using uninitialized variable: $c` against our `Bad parameter type!`.
#
# It is raised at `gget` (a global whose set-bit is clear) and at `gattr`
# (a slot still nil -- newobj fills every slot with nil and Ring's NULL is
# the empty STRING, so nil can only mean no assignment ever ran). The
# global's name comes from a per-slot table the image carries; the
# attribute's from the class's own entry table, walked on the error path.
#
# THE ROWS THAT DECIDE THE DESIGN: a global assigned only in a branch that
# never ran is R24 at RUNTIME (row 8), so this cannot be a compile-time
# refusal; a bare declaration in a class body (row 11) is NOT this case --
# Ring gives it the four-byte string "NULL".
#
# LEFT OUT ON PURPOSE: `$x = 42` inside a function whose unit has no global
# `$x`. Ring makes that a function-local and the top-level read is R24;
# under Rule A `$x` is the global and Ring++ answers 42. A decided
# divergence, recorded under C-2, not a defect.

? "-- 1. an unassigned $global, READ at the top level --"
try
    x = $zzNeverSet
    ? "  no error, got: <" + x + "> type " + type(x)
catch
    ? "  CAUGHT: " + cCatchError
done

? ""
? "-- 2. the same read inside a function --"
? "  " + zzRead()

? ""
? "-- 3. compared, not assigned --"
try
    if $zzNeverSet2 != 1
        ? "  no error, the comparison ran"
    ok
catch
    ? "  CAUGHT: " + cCatchError
done

? ""
? "-- 4. used as a subscript --"
aL = [10, 20, 30]
try
    ? "  aL[$zzNeverSet3] = " + aL[$zzNeverSet3]
catch
    ? "  CAUGHT: " + cCatchError
done

? ""
? "-- 5. in a concatenation, and as an argument --"
try
    x = "" + $zzInConcat
catch
    ? "  in concat : " + cCatchError
done
try
    zzTake($zzAsArg)
    ? "  no error"
catch
    ? "  as arg    : " + cCatchError
done

? ""
? "-- 6. ASSIGNED first, then read --"
$zzSet = 7
? "  $zzSet = " + $zzSet

? ""
? "-- 7. assigned NULL, then read: that is a value --"
$zzNull = NULL
? "  isNull=" + isNull($zzNull) + " len=" + len($zzNull) + " type=" + type($zzNull)

? ""
? "-- 8. assigned only in a branch that never ran: R24 at RUNTIME --"
if 1 = 2
    $zzBranch = 1
ok
try
    ? "  read: <" + $zzBranch + ">"
catch
    ? "  CAUGHT: " + cCatchError
done

? ""
? "-- 9. a top-level for variable, read after the loop --"
for zzI = 1 to 3
next
? "  zzI after the loop = " + zzI

? ""
? "-- 10. an unassigned @attribute --"
o = new zzK
? "  " + o.Read()

? ""
? "-- 11. an attribute DECLARED without a value: the string NULL --"
d = new zzD
? "  " + d.Read()

? ""
? "-- 12. an attribute assigned only in a branch that never ran --"
p = new zzE
? "  " + p.Read()

? ""
? "done"

func zzRead
    try
        y = $zzNeverSetF
        return "no error, got: <" + y + "> type " + type(y)
    catch
        return "CAUGHT: " + cCatchError
    done

func zzTake v
    return 0

class zzK
    @nSet = 1
    def Read()
        try
            return "@nUnset -> " + @nUnset
        catch
            return "CAUGHT: " + cCatchError
        done

class zzD
    nDeclared
    def Read()
        try
            return "declared, no value -> type " + type(nDeclared) + " len " + len(nDeclared) + " isNull " + isNull(nDeclared)
        catch
            return "CAUGHT: " + cCatchError
        done

class zzE
    @nSet = 0
    def init()
        if 1 = 2
            @nMaybe = 5
        ok
    def Read()
        try
            return "branch-only attribute -> <" + @nMaybe + ">"
        catch
            return "CAUGHT: " + cCatchError
        done
