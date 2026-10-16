# Softanza's ReplaceByMany, three ways — the Ring/Zig bridge, priced.
#
#     cd D:\GitHub\stzlib\libraries\stzlib
#     ring D:/GitHub/ringpp/bench/12_softanza_replace.ring
#
# It must run from Softanza's own directory, because `stzlib.ring` resolves
# its own `load` lines relative to the WORKING directory. Ring++ is loaded
# by absolute path for the same reason — and with FORWARD slashes, because
# a backslash inside a `load` path is a syntax error (C27) in Ring 1.27.
#
# WHAT THIS MEASURES. `stzString.ReplaceByMany` walks a text replacing every
# occurrence of a substring, cycling through a list of replacements. Its two
# helpers, `_FindFrom` and `_EngineSlice`, are engine-backed and each one
# does this:
#
#     _pH_ = StzEngineString(pcHay)      <-- the WHOLE haystack, per call
#     ... one engine operation ...
#     StzEngineStringFree(_pH_)
#
# The Zig engine is fast. The BRIDGE is not free: every call rebuilds the
# entire text on the other side and throws it away. With one find and one
# slice per occurrence, a text with k occurrences crosses the boundary 2k
# times carrying n bytes each — O(n*k) in copying, for O(n) of real work.
#
# THREE VARIANTS, all required to produce byte-identical output:
#
#   V0  Softanza as it ships
#   V1  the same algorithm and the same engine, with the handle built ONCE
#       outside the loop. This is not a Ring++ change — it is what the
#       bridge wants, and it is the fix Softanza itself should make.
#   V2  Ring++: RppBuffer holds the text, Peek() reads through a pointer,
#       and the boundary is never crossed at all.
#   V3  no engine and no Ring++ — twelve lines of plain Ring.
#
# THE RESULT IS NOT THE ONE THIS FILE WAS WRITTEN TO FIND. V3 wins, by a
# lot. `substr(hay, needle)` is a native C search and Ring's `+=` already
# doubles its capacity, so plain Ring does in 21 ms what the shipping path
# takes 202 ms to do. V2 is the SLOWEST: scanning byte by byte through
# RppBuffer costs two method calls per position, and ~1 us of interpreter
# per call cannot compete with a native search however cheap each read is.
#
# Ring++ is for holding one large value still and taking a FEW large slices
# of it. Used per byte, it is the wrong tool, and this file is the number
# that says so.
#
# ASCII ONLY, AND THAT IS A REAL LIMIT, NOT A CONVENIENCE. The engine works
# in CODEPOINTS; RppBuffer works in BYTES. On ASCII they agree and the
# outputs can be compared byte for byte. On UTF-8 they do not, and V2 is
# NOT a drop-in replacement for codepoint-aware code — it is the right tool
# for byte-oriented work and the wrong one for text that is not ASCII.

load "stzlib.ring"
load "D:/GitHub/ringpp/rpp/probe.ring"
load "D:/GitHub/ringpp/rpp/core.ring"
load "D:/GitHub/ringpp/rpp/idioms.ring"

cUnit = "The quick brown fox jumps over the lazy dog. TOKEN appears here. "
aNew  = ["<one>", "<two>", "<three>"]
nReps = 3

? "Softanza ReplaceByMany — the bridge, priced"
? copy("=", 62)
? ""
? "  bytes    occurrences   V0 ships    V1 handle once   V2 Ring++    V3 plain Ring"
? "  " + copy("-", 80)

for nUnits in [300, 600, 1200, 2400]
    cText = ""
    for i = 1 to nUnits cText += cUnit next
    nOcc = nUnits

    nA = -1
    for r = 1 to nReps
        o = new stzString(cText)
        nT = clock()
        o.ReplaceByMany("TOKEN", aNew)
        nMs = (clock()-nT)/clockspersecond()*1000
        if nA < 0 or nMs < nA nA = nMs ok
        cRef = o.Content()
    next

    nB = -1
    for r = 1 to nReps
        nT = clock()
        cOne = ReplaceHandleOnce(cText, "TOKEN", aNew)
        nMs = (clock()-nT)/clockspersecond()*1000
        if nB < 0 or nMs < nB nB = nMs ok
    next

    nC = -1
    for r = 1 to nReps
        nT = clock()
        cRpp = ReplaceRpp(cText, "TOKEN", aNew)
        nMs = (clock()-nT)/clockspersecond()*1000
        if nC < 0 or nMs < nC nC = nMs ok
    next

    nD = -1
    for r = 1 to nReps
        nT = clock()
        cPlain = ReplacePlainRing(cText, "TOKEN", aNew)
        nMs = (clock()-nT)/clockspersecond()*1000
        if nD < 0 or nMs < nD nD = nMs ok
    next

    # Correctness BEFORE any speed number reaches the screen.
    if cPlain != cRef
        ? "FATAL V3 differs from Softanza at " + nUnits + " units"
        return
    ok
    if cOne != cRef
        ? "FATAL V1 differs from Softanza at " + nUnits + " units"
        return
    ok
    if cRpp != cRef
        ? "FATAL V2 differs from Softanza at " + nUnits + " units"
        return
    ok

    ? "  " + _Pad("" + len(cText), 9) + _Pad("" + nOcc, 14) +
      _Pad(_Fmt(nA) + " ms", 12) + _Pad(_Fmt(nB) + " ms", 17) +
      _Pad(_Fmt(nC) + " ms", 13) + _Fmt(nD) + " ms"
next

? ""
? "  every row byte-identical across all four"
? "BENCH 12 OK"

### ------------------------------------------------------------ helpers

func _Fmt nX
    nR = floor(nX * 10 + 0.5)
    return "" + floor(nR / 10) + "." + (nR % 10)

func _Pad cS, n
    if len(cS) >= n return cS + " " ok
    return cS + copy(" ", n - len(cS))

# V1 — Softanza's own algorithm and Softanza's own engine, with the one
# change the bridge asks for: build the engine string ONCE, search and
# slice against that handle, free it at the end. Same results, same
# codepoint semantics, no Ring++ anywhere.
func ReplaceHandleOnce cText, cSub, aNew
    nRepLen = len(aNew)
    if nRepLen = 0 return cText ok
    pH = StzEngineString(cText)
    nSubLen = len(cSub)
    cOut = ""
    nPos = 1
    iRep = 1
    nFound = StzEngineStringFindFirstFromCS(pH, cSub, nPos, 1)
    while nFound > 0
        if nFound > nPos
            pSlc = StzEngineStringSlice(pH, nPos, nFound - nPos)
            cOut += StzEngineStringData(pSlc)
            StzEngineStringFree(pSlc)
        ok
        cOut += aNew[iRep]
        iRep++
        if iRep > nRepLen iRep = 1 ok
        nPos = nFound + nSubLen
        nFound = StzEngineStringFindFirstFromCS(pH, cSub, nPos, 1)
    end
    nLen = StzEngineStringCount(pH)
    if nPos <= nLen
        pSlc = StzEngineStringSlice(pH, nPos, nLen - nPos + 1)
        cOut += StzEngineStringData(pSlc)
        StzEngineStringFree(pSlc)
    ok
    StzEngineStringFree(pH)
    return cOut

# V2 — Ring++. The text is held once in an RppBuffer and every read goes
# through a pointer: Peek(off, len) costs the length of the SLICE, not the
# length of the text (F-6). The boundary into the engine is never crossed.
# Assembly uses Ring's own `+=`, which already doubles its capacity — this
# is the case where Ring++ deliberately does NOT offer a buffer.
func ReplaceRpp cText, cSub, aNew
    nRepLen = len(aNew)
    if nRepLen = 0 return cText ok
    nLen = len(cText)
    nSub = len(cSub)
    if nSub = 0 return cText ok
    oBuf = RppBufferFromString(cText)
    nFirst = ascii(cSub[1])      # Byte() returns a CODE, not a character

    cOut = ""
    nPrev = 0            # 0-based, start of the untouched run
    i = 0
    nLimit = nLen - nSub
    iRep = 1
    while i <= nLimit
        # One byte first: the cheapest possible rejection, and most
        # positions are rejected.
        if oBuf.Byte(i) = nFirst and oBuf.Peek(i, nSub) = cSub
            if i > nPrev cOut += oBuf.Peek(nPrev, i - nPrev) ok
            cOut += aNew[iRep]
            iRep++
            if iRep > nRepLen iRep = 1 ok
            i += nSub
            nPrev = i
        else
            i++
        ok
    end
    if nPrev < nLen cOut += oBuf.Peek(nPrev, nLen - nPrev) ok
    return cOut

# V3 — no engine, no Ring++, just Ring. `substr(hay, needle)` is a native C
# search, but Ring copies the haystack into it on every call (F-1), so the
# tail is re-copied once per occurrence. Included because "is Ring++ faster
# than plain Ring here?" is the only comparison that decides whether the
# library belongs in this code at all.
func ReplacePlainRing cText, cSub, aNew
    nRepLen = len(aNew)
    if nRepLen = 0 return cText ok
    nSub = len(cSub)
    cOut = ""
    cRest = cText
    iRep = 1
    nAt = substr(cRest, cSub)
    while nAt > 0
        if nAt > 1 cOut += left(cRest, nAt - 1) ok
        cOut += aNew[iRep]
        iRep++
        if iRep > nRepLen iRep = 1 ok
        cRest = substr(cRest, nAt + nSub)
        nAt = substr(cRest, cSub)
    end
    cOut += cRest
    return cOut
