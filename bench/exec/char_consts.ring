# Ring predefines three character constants -- nl, tab and cr -- and an
# ASSIGNMENT SHADOWS THEM. Probed on 1.27.
#
# Ring++ substituted the constant whenever there was no LOCAL of that name,
# which at the top level -- where an assignment makes a GLOBAL -- meant the
# name could never be written at all: `cR = "xyz"` then `len(cR)` was 1, and
# every later read returned a carriage return. perf/seams stores a refusal
# result in a variable called `cR`, which is how it surfaced (2026-09-14).

? "1 cr  unassigned : " + ascii(cr) + " len " + len(cr)
? "2 nl  unassigned : " + ascii(nl) + " len " + len(nl)
? "3 tab unassigned : " + ascii(tab) + " len " + len(tab)

cr = "xyz"
? "4 cr  = 'xyz'    : " + cr + " len " + len(cr)

nl = "abcd"
? "5 nl  = 'abcd'   : " + nl + " len " + len(nl)

tab = "ef"
? "6 tab = 'ef'     : " + tab + " len " + len(tab)

# case folds, as every Ring identifier does (F-18)
CR = "LMNOP"
? "7 CR  = 'LMNOP'  : " + cr + " len " + len(cr)
