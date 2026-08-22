### Regression: a Ring++ object must never touch its CALLER's variables.
###
### FINDINGS F-25. Ring resolves an attribute assignment inside a class
### against a caller variable of the same name and CLOBBERS it. RppBuffer's
### attributes used to be cData/nCap/pScratch/pSrcPtr/cNul and RppView's were
### oBuf/nOff/nLen -- all of them names a caller would plausibly use, and
### `cData` is one of the commonest names in the data-processing code this
### library is FOR.
###
### The existing suite could not see this. tests/fuzz_bounds.ring even
### contains `nCap = oB.Capacity()` -- a live collision -- and passed anyway,
### because the clobbered value happened to equal the value being read.
###
### Every variable below is deliberately named after a Ring++ attribute,
### past or present. If any assertion fails, the library is writing into
### its caller again.

load "../ringpp.ring"

nPass = 0
nFail = 0

### ---- the names RppBuffer used to use ------------------------------------

cData    = "CALLER OWNS THIS"
nCap     = 12345
pScratch = "caller scratch"
pSrcPtr  = "caller srcptr"
cNul     = "caller nul"

oB = new RppBuffer(64)
oB.Poke(0, "hello")
oB.PokeInt32(16, 256)
oB.PokeDouble(24, 1.5)
oB.Grow(128)
oB.Fill(40, 8, 65)

Check("cData survives RppBuffer",    cData = "CALLER OWNS THIS")
Check("nCap survives RppBuffer",     nCap = 12345)
Check("pScratch survives RppBuffer", pScratch = "caller scratch")
Check("pSrcPtr survives RppBuffer",  pSrcPtr = "caller srcptr")
Check("cNul survives RppBuffer",     cNul = "caller nul")
Check("buffer still correct",        oB.Peek(0, 5) = "hello")
Check("int32 round-trip",            oB.PeekInt32(16) = 256)
Check("double round-trip",           oB.PeekDouble(24) = 1.5)

### ---- the names RppView used to use --------------------------------------
###
### This is the shape that found the bug: the most natural loop anyone would
### write over length-prefixed records.

oBuf = new RppBuffer(1024)
oBuf.PokeInt32(0, 8)
oBuf.Poke(4, "ABCDEFGH")
oBuf.PokeInt32(12, 8)
oBuf.Poke(16, "IJKLMNOP")

nOff = 0
nLen = 0
nWalked = 0
for i = 1 to 2
    nLen  = oBuf.PeekInt32(nOff)
    oView = oBuf.View(nOff + 4, nLen)
    if oView.Size() = 8
        nWalked++
    ok
    nOff += 4 + nLen
next

Check("View does not clobber nOff",  nOff = 24)
Check("View does not clobber nLen",  nLen = 8)
Check("both records walked",         nWalked = 2)
Check("caller's oBuf still a buffer", oBuf.Capacity() = 1024)

### ---- a view over a live buffer is a WINDOW, not a snapshot ---------------

oW = oBuf.All()
oBuf.Poke(4, "ZZZZZZZZ")
Check("view sees later writes",      oW.Peek(4, 8) = "ZZZZZZZZ")

### ---- Sub() nests without collision --------------------------------------

oS = oBuf.View(4, 8).Sub(2, 4)
Check("nested Sub reads correctly",  oS.Str() = "ZZZZ")
Check("nOff still intact after Sub", nOff = 24)

? ""
? "name_collision: " + nPass + " passed, " + nFail + " failed"

func Check cWhat, bCond
    if bCond
        nPass++
    else
        nFail++
        ? "  FAIL  " + cWhat
    ok
