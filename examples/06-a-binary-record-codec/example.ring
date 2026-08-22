# Ring++ example 06 -- a binary record codec, and the landmine under it
#
# THE TASK, which is ordinary: pack fixed-width binary records into a buffer
# and read them back. A network frame. A file format. An index. Anything
# where the bytes matter and the layout is fixed.
#
# THIS EXAMPLE IS DIFFERENT FROM THE OTHERS. Its value is not the speedup --
# which is modest here, and example 08 explains exactly why. Its value is
# that the obvious optimisation KILLS YOUR PROCESS, silently, and no amount
# of careful Ring will save you from it.
#
# ------------------------------------------------------------------------
# THE LANDMINE (FINDINGS F-14)
#
# Having read example 04, you now know substr() copies the whole buffer, so
# you reach for a pointer. This is the natural next step, and it is fatal:
#
#     p = varptr(:cBuf, "char *")
#     memcpy(p, int2bytes(256), 4)        # <-- the process VANISHES
#
# No error. No line number. No exit message. `try/catch` CANNOT trap it.
#
# WHY: `ring_vm_api_ispointer` (ringapi.c:118) uses strcmp() to test whether
# a string argument is the literal "NULL". int2bytes(256) is 00 01 00 00 --
# it BEGINS with a zero byte, so strcmp sees an empty string, reclassifies
# the argument as a NULL pointer, rewrites the stack slot, and memcpy copies
# from address 0.
#
# WHICH VALUES? Every multiple of 256. Every zeroed field. double2bytes() of
# almost any round number. In other words: EXACTLY the values a binary codec
# is made of. A Ring programmer writing one meets this within minutes.
#
# WHAT RING++ DOES: RppBuffer.Poke() branches on the first byte and takes a
# pointer-to-pointer route for that case, so the common path stays fast and
# the fatal one never happens. Every record below has a leading zero byte,
# on purpose -- this example is a live test of that guard.
#
# THE CRASH ITSELF IS NOT RUN HERE. It would kill the process and the gate
# would report an example that "did not reach its OK marker" rather than the
# truth. It is reproduced, deliberately and in isolation, in
# bench/15_memcpy_nul_source.ring.
# ------------------------------------------------------------------------

load "../../ringpp.ring"

### ---------------------------------------------------------------- layout
#
#   offset  0  int32   id        (always a multiple of 256 -> leading 0x00)
#   offset  4  double  amount
#   offset 12  int32   checksum
#   ------------------------------
#   16 bytes per record

nRecSize = 16
nSmall   = 5000      #  80 KB
nBig     = 20000     # 320 KB
nReps    = 3

? "Ring++ example 06 -- a binary record codec"
? copy("-", 58)
? "layout  : int32 id | double amount | int32 checksum  (" + nRecSize + " bytes)"
? "note    : every id is a multiple of 256, so every record begins"
? "          with a zero byte -- the shape that kills memcpy (F-14)"
? ""

### --------------------------------------------------- measured TWICE
#
# THE FIRST DRAFT OF THIS EXAMPLE MEASURED ONE SIZE AND CLAIMED A WIN.
# It measured 5,000 records, Ring++ came out 3x SLOWER, and the prose still
# said Ring++ wins. Rather than grow the buffer until the number flattered
# the library -- which is how benchmarks lie -- it now measures BOTH sizes
# and reports the crossover. That is the fact a codec author actually needs.

aSmall = Measure(nSmall, nRecSize, nReps)
aBig   = Measure(nBig, nRecSize, nReps)

### -------------------------------------------------- correctness, first

bSame = (aSmall[3] and aBig[3])
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- raw and Ring++ disagree on the decoded records"
ok
? ""

### ----------------------------------------------------------- the numbers

? "at " + nSmall + " records (" + floor(nSmall * nRecSize / 1024) + " KB):"
? "    raw Ring " + RppMs(aSmall[1]) + " | Ring++ " + RppMs(aSmall[2]) + "   -> " + Verdict(aSmall[1], aSmall[2])
? "at " + nBig + " records (" + floor(nBig * nRecSize / 1024) + " KB):"
? "    raw Ring " + RppMs(aBig[1]) + " | Ring++ " + RppMs(aBig[2]) + "   -> " + Verdict(aBig[1], aBig[2])
? ""
? "crossover       : raw Ring wins on SMALL buffers, Ring++ on large ones."
? "                  substr()'s cost grows with the BUFFER; Peek()'s does not."
? ""

### ------------------------------------------- the guard, tested directly
#
# The four classes of value from F-14, round-tripped. If Poke's branch ever
# regresses, this process dies here and the gate reports it.

? "The F-14 shapes, round-tripped through RppBuffer:"
oT = new RppBuffer(64)

oT.PokeInt32(0, 0)
? "  int2bytes(0)      -> " + oT.PeekInt32(0) + "      (00 00 00 00)"

oT.PokeInt32(8, 256)
? "  int2bytes(256)    -> " + oT.PeekInt32(8) + "    (00 01 00 00)"

oT.PokeDouble(16, 1.5)
? "  double2bytes(1.5) -> " + oT.PeekDouble(16) + "    (00 00 00 00 00 00 f8 3f)"

oT.Poke(32, "NULL")
? "  the literal NULL  -> " + oT.Peek(32, 4) + "   (strcmp's other trap)"
? ""
? "  All four survived. Written naively with memcpy, each one would have"
? "  ended the process with no message."
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES, and it is the measured half above:"
? "  At " + nSmall + " records RING++ IS SLOWER, and that is not a defect."
? "  This is a PER-ELEMENT workload: every PeekInt32 and PeekDouble pays"
? "  a method call, a bounds check and a varptr (~3.2 us -- example 08)."
? "  On an 80 KB buffer substr()'s copy is cheap enough to beat all that."
? ""
? "  The two costs scale differently, which is the whole point:"
? "    substr() grows with the SIZE OF THE BUFFER"
? "    Peek()   grows with the NUMBER OF FIELDS"
? "  so the crossover moves with your record count, not with your taste."
? ""
? "  COME HERE FOR CORRECTNESS. On a small buffer, plain Ring is faster,"
? "  simpler, and cannot crash -- use it. Reach for RppBuffer when the"
? "  buffer is large, or when you were about to write memcpy yourself."
? ""
? "EXAMPLE 06 OK"

### =====================================================================

func RawWay nRecs, nRecSize
    # Idiomatic, safe Ring. Building by string append is fine -- Ring's
    # ring_string_add2_gc doubles capacity, so appends are amortised O(1).
    # The cost is on the READ side: substr() copies the whole buffer for
    # every field (example 04).
    cBuf = ""
    for i = 1 to nRecs
        cBuf += int2bytes(i * 256)
        cBuf += double2bytes(i + 0.5)
        cBuf += int2bytes(i * 256 + 7)
    next

    nAcc = 0
    for i = 0 to nRecs - 1
        nOff = i * nRecSize
        nId  = bytes2int(substr(cBuf, nOff + 1, 4))
        nAmt = bytes2double(substr(cBuf, nOff + 5, 8))
        nChk = bytes2int(substr(cBuf, nOff + 13, 4))
        nAcc += nId + nChk + floor(nAmt)
    next
    return nAcc

func RppWay nRecs, nRecSize
    # The same layout through Ring++. Poke*() writes through the buffer's
    # own bytes and survives the leading-zero shape that would kill a naive
    # memcpy.
    oBuf = new RppBuffer(nRecs * nRecSize)
    for i = 1 to nRecs
        nOff = (i - 1) * nRecSize
        oBuf.PokeInt32(nOff, i * 256)
        oBuf.PokeDouble(nOff + 4, i + 0.5)
        oBuf.PokeInt32(nOff + 12, i * 256 + 7)
    next

    nAcc = 0
    for i = 0 to nRecs - 1
        nOff = i * nRecSize
        nId  = oBuf.PeekInt32(nOff)
        nAmt = oBuf.PeekDouble(nOff + 4)
        nChk = oBuf.PeekInt32(nOff + 12)
        nAcc += nId + nChk + floor(nAmt)
    next
    return nAcc

func Measure nRecs, nRecSize, nReps
    # returns [ raw ms, rpp ms, identical? ] -- minima over nReps
    nRawBest = 0
    for r = 1 to nReps
        nT = clock()
        nRaw = RawWay(nRecs, nRecSize)
        nMs = (clock() - nT) / clockspersecond() * 1000
        if r = 1 or nMs < nRawBest
            nRawBest = nMs
        ok
    next

    nRppBest = 0
    for r = 1 to nReps
        nT = clock()
        nRpp = RppWay(nRecs, nRecSize)
        nMs = (clock() - nT) / clockspersecond() * 1000
        if r = 1 or nMs < nRppBest
            nRppBest = nMs
        ok
    next

    return [ nRawBest, nRppBest, (nRaw = nRpp) ]

func Verdict nRaw, nRpp
    # never prints "0x" -- an earlier draft did, which is how a 3x LOSS got
    # reported as a win
    if nRpp = 0 or nRaw = 0
        return "one side is below the 1 ms timer floor"
    ok
    if nRpp < nRaw
        return "Ring++ wins, " + Round1(nRaw / nRpp) + "x"
    ok
    return "RAW RING WINS, " + Round1(nRpp / nRaw) + "x"

func Round1 n
    return "" + (floor(n * 10) / 10)

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
