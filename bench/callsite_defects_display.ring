# The display half of the call-site defects, kept separate because the
# R20 in callsite_defects.ring stops that program.
#
#     ring callsite_defects_display.ring
#
# `?` erases the structure entirely: the two lists below -- one nested,
# one flat -- print IDENTICALLY. That is the whole defect in two lines.

aNested = [ 1, [ [ "name", "Ali" ], [ "age", 52 ] ], 2 ]
aFlat   = [ 1, "name", "Ali", "age", 52, 2 ]

? "--- ? aNested"
? aNested

? "--- ? aFlat  (a DIFFERENT list -- compare the two outputs)"
? aFlat

? "--- list2code(aNested): structure kept, one atom per line"
? "    (needs load 'stdlib.ring' -- it is not a builtin: R3 without it)"
load "stdlib.ring"
? list2code(aNested)

? "--- what Softanza's @@() gives, for comparison:"
? '    [ 1, [ [ "name", "Ali" ], [ "age", 52 ] ], 2 ]'
