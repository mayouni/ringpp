# `call x()` where x is not a function: Ring has TWO answers, and Ring++
# had neither -- it panicked, and three tests in the wide clock died there.
#
# Measured on 1.27, both catchable, the program running on afterwards:
#
#     a NUMBER or a LIST   Error (R32) : The CALL command expect a
#                          variable contains string
#     a STRING             the string is a FUNCTION NAME. It is called,
#                          and a miss is R3 with the name.
#
# The string form is not a curiosity: the estate's router keeps its handlers
# by NAME and calls them, which is why appserver/61_router_params reported
# "Handler error" on every route.
#
# THE LIST CASE IS WHY THE CLOSURE ID IS BIASED. On Ring a lambda is a
# STRING -- its generated name -- so a list is never a function there. Ours
# is a LIST, `[func_id, captured...]`, so without a mark the two are the
# same shape and `call aList()` would reach fn_entry[aList[1]] and call
# whatever function that happened to be. The id is stored at 2^30 + id and
# `calli` refuses anything smaller, which gets R32 to the same programs Ring
# gives it to.

? "-- a number is not a function --"
n = 5
try  call n()  catch ? "  " + cCatchError done

? ""
? "-- nor is a list, however function-shaped its contents --"
aL = [1, 2, 3]
try  call aL()  catch ? "  " + cCatchError done
aOne = [1]
try  call aOne()  catch ? "  " + cCatchError done
aEmpty = []
try  call aEmpty()  catch ? "  " + cCatchError done

? ""
? "-- a STRING is a function NAME --"
cName = "Doubled"
? "  call by name : " + call cName(21)

cMixed = "DOUBLED"
? "  case folded  : " + call cMixed(21)

cMissing = "no_such_function_anywhere"
try  call cMissing()  catch ? "  " + cCatchError done

? ""
? "-- and a real lambda still runs --"
f = func x { return x * 2 }
? "  lambda       : " + call f(21)

# A lambda that reads a top-level name was a defect of ours when this file
# was written -- `n = 10; f = func x { return x + n }; ? call f(32)` gave
# R2 where Ring gives 42, because scanCaptures took `n` as a capture and
# the closure build pushed nothing for it. FIXED 2026-09-22: such a name is
# a GLOBAL READ performed when the lambda runs, never a capture, and
# bench/exec/lambda_global.ring pins it. It belonged to the lambda's
# free-name rule, not to `call`.
#
# Taking the lambda out of a list first is fine, and `call aList[i](...)` is
# not parsed by Ring at all (C31), so it is not probed either.
aFuncs = [ func a { return a * 2 }, func a { return a * 3 } ]
g = aFuncs[1]
h = aFuncs[2]
? "  from a list  : " + call g(21) + " " + call h(14)

? ""
? "done"

func Doubled n
    return n * 2
