# The price of named parameters in Ring, measured.
#
# Ring has no named arguments. `:AtPositions = 1` is a hash pair, so the
# function receives a LIST and must decide at run time whether it is data
# or a parameter name. Softanza implements named parameters anyway --
# thousands of them -- with a check at the top of function after
# function:
#
#     if isList(pcSubStr) and Q(pcSubStr).IsOfOrOfSubStringNamedParam()
#
# Q(...) CONSTRUCTS AN OBJECT to ask the question. Some call sites chain
# eight of these with `or`, one per accepted spelling.
#
# This measures the difference and nothing else: same object, same
# method, construction hoisted OUT of the loop, so the only thing that
# differs between the two runs is the call form. (A first attempt left
# `new stzList(...)` inside the loop; at 214 us it swamped the effect
# entirely and the answer came out meaningless.)
#
# It needs Softanza on the load path, so run it from the library root:
#
#     copy this file to D:\GitHub\stzlib\libraries\stzlib\
#     ring named_params_cost.ring
#
# Measured 2026-08-31, Ring 1.27, two independent runs:
#
#     positional      122-124 us per call
#     named           130     us per call
#     overhead        +6.3 to +7.8 us per call
#
# Python, same shape, keyword against positional: +0.012 us (11.7 ns).
# So Ring's named-parameter overhead is roughly 550x Python's.

load "stzlib.ring"

nReps = 5
nIter = 20000

o = new stzList([ "C", "B", "A" ])

# --- A: positional
nBestPos = 999999999
for r = 1 to nReps
    t = clock()
    for i = 1 to nIter
        o.SwapItems(1, 3)
    next
    e = clock() - t
    if e < nBestPos nBestPos = e ok
next

# --- B: named -- the ONE thing that differs
nBestNam = 999999999
for r = 1 to nReps
    t = clock()
    for i = 1 to nIter
        o.SwapItems( :AtPositions = 1, :And = 3 )
    next
    e = clock() - t
    if e < nBestNam nBestNam = e ok
next

? "iterations               : " + nIter
? "positional          (ms) : " + nBestPos
? "named               (ms) : " + nBestNam
? "per call positional (us) : " + (nBestPos * 1000 / nIter)
? "per call named      (us) : " + (nBestNam * 1000 / nIter)
? "overhead per call   (us) : " + ((nBestNam - nBestPos) * 1000 / nIter)
? "named / positional       : " + (nBestNam / nBestPos)
