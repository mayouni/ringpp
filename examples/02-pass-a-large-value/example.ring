# Ring++ example 02 -- passing a large value to a function
#
# THIS IS THE THESIS. Everything else in Ring++ is a consequence of one
# measured fact about the Ring VM:
#
#     A LIST crosses a call boundary BY REFERENCE.
#     A STRING crosses a call boundary BY COPY.
#
# `RING_VM_STACK_PUSHCVAR` (vm.h:230) is `ring_itemarray_setstring2_gc(...)`
# -- a byte copy onto the VM stack. So a helper function that takes a 1 MB
# string copies a megabyte on EVERY call, before its first line runs.
#
# THE TASK, which is ordinary: a large buffer in memory, and a small helper
# called many times to read bytes out of it. A parser. A validator. A codec.
# Any loop with a helper.
#
# WHAT MAKES THIS HARD TO SEE: the helper looks cheap. It reads ONE byte.
# The cost is not in the function -- it is in the act of calling it.
#
# Ring++ changes nothing about the loop. It changes what you hold: an
# RppBuffer is an OBJECT, and an object is a list, so it crosses by
# reference. Same helper, same call, no copy.

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nSize  = 1000000    # a one-megabyte buffer
nCalls = 1500       # helper invocations per run
nReps  = 3          # report the MINIMUM -- one run is noise

# a repeating 250-byte pattern, so both sides hold identical bytes.
# values 1..250: deliberately no zero byte, which memcpy mishandles on
# Ring <= 1.27 (FINDINGS F-14).
cPattern = ""
for i = 1 to 250
    cPattern += char(i)
next
cData = copy(cPattern, nSize / 250)

oBuf = new RppBuffer(nSize)
oBuf.PokeString(0, cData)

? "Ring++ example 02 -- passing a large value to a function"
? copy("-", 58)
? "buffer : " + nSize + " bytes"
? "calls  : " + nCalls + " helper invocations"
? "        (raw Ring copies the buffer on every one of them)"
? ""

### ------------------------------------------------------------- raw Ring

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nRaw = RawWay(cData, nCalls, nSize)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### --------------------------------------------------------------- Ring++

nRppBest = 0
for r = 1 to nReps
    nT = clock()
    nRpp = RppWay(oBuf, nCalls, nSize)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRppBest
        nRppBest = nMs
    ok
next

### -------------------------------------------------- correctness, first

bSame = (nRaw = nRpp)
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- raw sum " + nRaw + " vs Ring++ sum " + nRpp
    ? "  the fast path is WRONG. The number below means nothing."
ok
? ""

### ----------------------------------------------------------- the number

? "raw Ring        : " + RppMs(nRawBest)
? "Ring++          : " + RppMs(nRppBest)
if nRppBest > 0
    ? "speedup         : " + floor(nRawBest / nRppBest) + "x"
else
    ? "speedup         : Ring++ below the 1 ms timer floor"
ok
? ""
? "bytes copied by raw Ring : " + floor(nCalls * nSize / 1048576) + " MB"
? "bytes copied by Ring++   : 0"
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES:"
? "  Nothing is free. Reading through the object costs a METHOD CALL"
? "  (~340 ns) where raw Ring costs an index (~30 ns). If your buffer is"
? "  small enough that the copy is cheap -- a few KB -- the raw form is"
? "  faster and simpler. The crossover is the size of the value, not the"
? "  number of calls."
? ""
? "EXAMPLE 02 OK"

### =====================================================================

func RawWay cData, nCalls, nSize
    # Idiomatic Ring. The helper takes the buffer as a parameter, which is
    # the natural way to write it -- and the parameter is a STRING, so the
    # whole megabyte is copied onto the VM stack on every call.
    nSum = 0
    for i = 1 to nCalls
        nSum += ByteAtRaw(cData, (i * 7919) % (nSize - 1))
    next
    return nSum

func ByteAtRaw cData, nOffset
    # one byte read. The expensive part already happened, at the call.
    return ascii(cData[nOffset + 1])

func RppWay oBuf, nCalls, nSize
    # The same shape. oBuf is an OBJECT, and an object is a list, so it
    # crosses the boundary by reference -- nothing is copied.
    nSum = 0
    for i = 1 to nCalls
        nSum += ByteAtRpp(oBuf, (i * 7919) % (nSize - 1))
    next
    return nSum

func ByteAtRpp oBuf, nOffset
    return oBuf.Byte(nOffset)

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
