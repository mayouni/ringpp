# A FREE NAME IN A LAMBDA THAT NAMES A TOP-LEVEL GLOBAL IS A GLOBAL READ,
# performed when the lambda RUNS -- not a capture taken when it is built.
#
# Ring++ used to treat every free name as a capture. `scanCaptures` runs
# before codegen and cannot know whether a name is a local of the enclosing
# scope -- its own comment says so -- so it took them all, and the closure
# build did `lookup(cap) orelse continue`, pushing NOTHING for the ones that
# were not locals. The closure came out a slot short and the body indexed
# past it: three lines answered `Error (R2) : Array Access (Index out of
# range)` where Ring answers 42.
#
#     n = 10
#     f = func x { return x + n }
#     ? call f(32)
#
# THE MEASUREMENT THAT DECIDED THE FIX is row 1 below. Capturing by value at
# creation would answer 42; Ring answers 132, because it reads the global
# when the lambda runs. Row 2 settles it beyond argument: the name is not
# assigned until AFTER the lambda exists, which no capture-at-creation
# scheme can do at all.
#
# So a capture is only a name that resolves to an ENCLOSING LOCAL. The
# closure build drops the rest and the body reads them as globals, and the
# two sides agree on the slots because the enclosing function is always
# emitted before the lambda inside it.
#
# What this does NOT change: a lambda capturing a local of the defining
# FUNCTION. Ring cannot see one at all (R24); Ring++ captures it. That is a
# registered divergence -- clos:C2 to C5 in bench/ab-known.txt -- so it is
# tested there and cannot be tested here, where every line must match Ring.

? "-- 1. the global is read when the lambda RUNS --"
n = 10
f = func x { return x + n }
n = 100
? "  after n became 100 : " + call f(32)

? ""
? "-- 2. and a name assigned only AFTER the lambda is built still reads --"
g = func x { return x + m }
m = 5
? "  m set afterwards   : " + call g(1)

? ""
? "-- 3. an explicit $global inside a lambda, the same way --"
$p = 7
h = func x { return x + $p }
$p = 70
? "  $p now 70          : " + call h(1)

? ""
? "-- 4. a lambda INSIDE a function reading a top-level name --"
? "  from inside Outer  : " + Outer(1)

? ""
? "-- 5. two free globals in one lambda --"
a1 = 3
b1 = 4
k = func x { return x * a1 + b1 }
? "  two of them        : " + call k(10)

? ""
? "done"

func Outer a
    k2 = func x { return x + n }
    return "" + call k2(a)
