# RING HAS NO ONE-LINE `if cond: stmt ok`. The `:` is the RANGE operator,
# and this is a Ring trap that costs the estate a real defect.
#
#     if _bUp_: _nConnections_++ ok
#
# reads as a guarded increment and is nothing of the kind. `_bUp_ :
# _nConnections_++` builds a LIST -- eagerly, so the increment happens
# WHATEVER _bUp_ is -- and a list is truthy, so the (empty) `if` body always
# runs. stzSurfacePlot.ring:697-700 has four of them in a row, so
# `_nConnections_` counts 4 every time instead of counting the true ones.
#
# Probed on 1.27, rows 1 and 2 below: the increment fires with the condition
# FALSE. Ring++ reproduces it, because reproducing Ring is the job -- the
# defect is named in CLAUDE.md for Mansour rather than silently fixed by a
# compiler that guesses what he meant.
#
# Row 3 is the other half of the trap: inside a range, `m = 5` is a
# COMPARISON and not an assignment, so the would-be one-line if does not
# even do the thing it looks like it does.
#
# Row 5 is where the illusion ends -- `if c: ? "hi" ok` is a COMPILE error
# on Ring (C28, Expression is expected), because `?` is not an expression
# and the `:` wanted one.

? "-- 1. the condition is FALSE and the increment fires anyway --"
bUp = 0
n = 0
if bUp: n++ ok
? "  bUp = 0, n = " + n

? ""
? "-- 2. and with it true, exactly the same --"
bUp2 = 1
n2 = 0
if bUp2: n2++ ok
? "  bUp = 1, n = " + n2

? ""
? "-- 3. an assignment in that position is a COMPARISON --"
m = 0
c = 1
if c = 1: m = 5 ok
? "  m = " + m + "   (5 if it were an assignment)"

? ""
? "-- 4. because `a : b` is a range, and a list --"
r = 1:4
? "  1:4 is a " + type(r) + " of len " + len(r) + " : " + r[1] + "," + r[4]

? ""
? "-- 5. the list is truthy, so even `if 0:` runs --"
k = 0
if 0: k++ ok
? "  if 0: k++ ok  ->  k = " + k

? ""
? "done"
