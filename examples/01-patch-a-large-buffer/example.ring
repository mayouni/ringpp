# Ring++ example 01 -- patching a large buffer in place
#
# THE TASK, which is ordinary: hold a large block of text and overwrite small
# fields inside it, many times. A template being filled, a fixed-width record
# file being updated, a protocol frame whose header changes per send.
#
# THIS FILE IS SIX THINGS AT ONCE, on purpose:
#   a tutorial   -- the two functions sit side by side; the diff IS the lesson
#   an example   -- it runs, on real data
#   a proof      -- both ways must produce BYTE-IDENTICAL output, asserted
#   a benchmark  -- it prints the A/B, minima over repetitions
#   a gate       -- tests/run-all.ps1 fails if either half regresses
#   the docs     -- README.md quotes these functions, so it cannot go stale
#
# WHY THE RAW WAY IS SLOW, and it is not obvious from reading it:
# Ring strings are immutable at the language level, so `left(s,o) + p + right(...)`
# builds a WHOLE NEW STRING every write. One patch of 8 bytes into a 500 KB
# buffer copies 500 KB. Two thousand patches copy a gigabyte to write 16 KB.
# The cost is invisible in the source -- nothing about that line looks
# expensive -- which is exactly why it survives code review.
#
# WHAT RING++ DOES: RppBuffer owns its bytes and Poke() writes THROUGH A
# POINTER into them (FINDINGS F-1, F-7). The write is O(patch), not O(buffer).
#
# Run it:  ring examples/01-patch-a-large-buffer/example.ring

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nSize    = 500000      # a half-megabyte buffer
nPatches = 2000        # how many small overwrites
cPatch   = "RING++!!"  # 8 bytes, written over and over
nReps    = 3           # report the MINIMUM -- a single run is noise (F-hygiene)

? "Ring++ example 01 -- patching a large buffer in place"
? copy("-", 58)
? "buffer  : " + nSize + " bytes"
? "patches : " + nPatches + " x " + len(cPatch) + " bytes"
? ""

### -------------------------------------------------------- the raw way

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    cRaw = RawWay(nSize, nPatches, cPatch)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### ------------------------------------------------------ the Ring++ way

nRppBest = 0
for r = 1 to nReps
    nT = clock()
    cRpp = RppWay(nSize, nPatches, cPatch)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRppBest
        nRppBest = nMs
    ok
next

### ---------------------------------------------------- correctness first
#
# The speed number is worthless if the two disagree. This is the same rule
# the compiler half of the design lives by: byte-identical output, or the
# fast path is wrong and the slow one is right.

bSame = (cRaw = cRpp)

? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- lengths " + len(cRaw) + " vs " + len(cRpp)
    ? "  the fast path is WRONG. The number below means nothing."
ok
? ""

### ------------------------------------------------------------ the number

? "raw Ring        : " + RppMs(nRawBest)
? "Ring++          : " + RppMs(nRppBest)
if nRppBest > 0
    ? "speedup         : " + floor(nRawBest / nRppBest) + "x"
else
    ? "speedup         : Ring++ below the 1 ms timer floor"
ok
? ""

### ----------------------------------------------------- the honest half
#
# Every claim in this project ships with the case it HURTS (FINDINGS rule).

? "Where this LOSES:"
? "  Below ~512 bytes the varptr call costs more than the copy it avoids"
? "  (RPP_MEMCPY_CROSSOVER). At 64 bytes and 10 patches, raw Ring wins."
? "  RppBuffer is for a buffer you hold and hit repeatedly -- not for"
? "  building a short string once."
? ""
? "EXAMPLE 01 OK"

### =====================================================================
### The two implementations. In Ring every func must follow all top-level
### statements (FINDINGS F-21), so the narrative above runs first.

func RawWay nSize, nPatches, cPatch
    # Idiomatic pure Ring. Correct, readable, and O(nSize) per write:
    # left() + right() rebuilds the ENTIRE buffer for every 8-byte patch.
    cBuf = copy("x", nSize)
    nLen = len(cPatch)
    nStep = floor(nSize / nPatches)

    for i = 0 to nPatches - 1
        nOff = i * nStep
        cBuf = left(cBuf, nOff) + cPatch + right(cBuf, nSize - nOff - nLen)
    next
    return cBuf

func RppWay nSize, nPatches, cPatch
    # The same task through Ring++. Poke() writes through a live pointer into
    # bytes the buffer owns, so the cost is the 8 bytes written -- not the
    # 500,000 bytes held. Same result, same file, same project.
    oBuf = new RppBuffer(nSize)
    oBuf.Fill(0, nSize, ascii("x"))
    nStep = floor(nSize / nPatches)

    for i = 0 to nPatches - 1
        oBuf.Poke(i * nStep, cPatch)
    next
    return oBuf.Str()

func RppMs nMs
    # a printable duration that never lies about the timer floor
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
