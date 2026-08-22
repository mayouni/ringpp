# Ring++ example 04 -- slicing a large string in a loop
#
# THE TASK, which is ordinary: pull many small fields out of one big block
# of text. Fixed-width records. A log scanner. A tokenizer. Anything that
# says "give me 16 bytes from offset N", thousands of times.
#
# THE TRAP: `substr()` COPIES THE WHOLE STRING before taking the slice.
#
# Not the slice -- the string. Asking for 16 bytes out of a megabyte copies
# a megabyte. The cost scales with the size of the SOURCE, not the size of
# the piece you asked for, which is the opposite of what the code looks like
# it does. (FINDINGS F-6; Central measured 316 us for a ONE-CHARACTER
# substr on a 1.8 MB buffer, against 0.07 us for `s[i]`.)
#
# WHAT RING++ DOES: RppBuffer.Peek() reads through a live pointer into bytes
# the buffer owns. The cost is the 16 bytes you asked for.
#
# THE SAME TRAP, WITHOUT RING++: for a SINGLE character, plain `s[i]` does
# not copy and is already fast. Ring++ is for the case where you need a
# RANGE. That distinction is worth more than this example's speedup.

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nSize   = 1000000    # one megabyte of text
nSlices = 2000       # fields to extract
nWidth  = 16         # bytes per field
nReps   = 3

cPattern = copy("ABCDEFGHIJ", 5)      # 50 printable bytes
cData    = copy(cPattern, nSize / 50)

oBuf = new RppBuffer(nSize)
oBuf.PokeString(0, cData)

? "Ring++ example 04 -- slicing a large string in a loop"
? copy("-", 58)
? "source : " + nSize + " bytes"
? "slices : " + nSlices + " x " + nWidth + " bytes"
? "        (substr copies the SOURCE, not the slice, every time)"
? ""

### ------------------------------------------------------------- raw Ring

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nRaw = RawWay(cData, nSlices, nWidth, nSize)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### --------------------------------------------------------------- Ring++

nRppBest = 0
for r = 1 to nReps
    nT = clock()
    nRpp = RppWay(oBuf, nSlices, nWidth, nSize)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRppBest
        nRppBest = nMs
    ok
next

### -------------------------------------------------- correctness, first

bSame = (nRaw = nRpp)
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- raw " + nRaw + " vs Ring++ " + nRpp
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
? "bytes touched, raw Ring : " + floor(nSlices * nSize / 1048576) + " MB"
? "bytes touched, Ring++   : " + floor(nSlices * nWidth / 1024) + " KB"
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES:"
? "  For ONE character, plain s[i] does not copy and is already fast --"
? "  ~0.07 us against substr's 316 us on a large buffer. Reach for Ring++"
? "  when you need a RANGE, not a character."
? "  And on a SMALL source substr is fine: the copy it makes is small."
? "  The cost is the size of what you are slicing FROM."
? ""
? "  Peek() is bounds-checked. RppView.Sub() over a region you have"
? "  already validated skips the re-check when you have measured and"
? "  need it -- but the check is what makes the example safe by default."
? ""
? "EXAMPLE 04 OK"

### =====================================================================

func RawWay cData, nSlices, nWidth, nSize
    # Idiomatic Ring, and the natural way to write it. substr() is 1-based.
    nAcc = 0
    for i = 1 to nSlices
        nOff = (i * 7919) % (nSize - nWidth)
        cField = substr(cData, nOff + 1, nWidth)
        nAcc += Fingerprint(cField)
    next
    return nAcc

func RppWay oBuf, nSlices, nWidth, nSize
    # Same loop, same offsets. Peek() is 0-based and reads through the
    # buffer's own bytes.
    nAcc = 0
    for i = 1 to nSlices
        nOff = (i * 7919) % (nSize - nWidth)
        cField = oBuf.Peek(nOff, nWidth)
        nAcc += Fingerprint(cField)
    next
    return nAcc

func Fingerprint cField
    # cheap, but it depends on BOTH ends and the length -- so a wrong
    # offset or a wrong width shows up in the assertion rather than
    # hiding behind a matching total.
    return ascii(cField[1]) + ascii(cField[len(cField)]) * 3 + len(cField)

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
