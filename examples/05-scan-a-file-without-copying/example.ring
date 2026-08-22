# Ring++ example 05 -- scanning a file without copying it
#
# THE TASK, which is ordinary: read a data file of length-prefixed records
# and walk it, doing something with each record's payload. A log. A binary
# export. A wire capture. Anything you read once and scan.
#
# THE SHAPE OF THE FILE:
#
#     [4-byte length][payload ...][4-byte length][payload ...] ...
#
# RAW RING: read() hands you the whole file as a STRING, and from then on
# every field costs a substr() -- which copies the WHOLE file to hand you a
# few bytes (example 04). Scanning a 1 MB file with 5,000 records copies
# gigabytes to read megabytes.
#
# RING++: LoadFile() puts the bytes in a buffer that owns them, and View()
# hands out a WINDOW over a region -- an object, so it crosses call
# boundaries by reference (example 02) and costs nothing to pass around.
#
# THIS EXAMPLE IS THE COMPOSITION ONE. Examples 02 and 04 each showed one
# piece; here the file, the buffer and the view work together, and a payload
# handler receives a view instead of a copied string.

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

cFile   = "_example05_data.bin"
nRecs   = 5000
nPay    = 200          # payload bytes per record
nReps   = 3

# Build the file once. Not timed -- this is the setup, not the task.
oGen = new RppBuffer(nRecs * (4 + nPay))
cPay = copy("ABCDEFGHIJ", nPay / 10)
for i = 1 to nRecs
    nOff = (i - 1) * (4 + nPay)
    oGen.PokeInt32(nOff, nPay)
    oGen.Poke(nOff + 4, cPay)
next
oGen.SaveFile(cFile, oGen.Capacity())

nBytes = oGen.Capacity()

? "Ring++ example 05 -- scanning a file without copying it"
? copy("-", 58)
? "file    : " + cFile + "  (" + floor(nBytes / 1024) + " KB)"
? "records : " + nRecs + " x [4-byte length][" + nPay + "-byte payload]"
? ""

### ------------------------------------------------------------- raw Ring

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nRaw = RawWay(cFile, nRecs, nPay)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

### --------------------------------------------------------------- Ring++

nRppBest = 0
for r = 1 to nReps
    nT = clock()
    nRpp = RppWay(cFile, nRecs, nPay, nBytes)
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
? "bytes copied, raw Ring : " + floor(nRecs * 2 * nBytes / 1048576) + " MB"
? "bytes copied, Ring++   : " + floor(nBytes / 1024) + " KB   (the file, once)"
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES:"
? "  If you read a file and touch it ONCE -- say, hand the whole thing to"
? "  a regex -- read() is right and this is pointless. The win here comes"
? "  from scanning the SAME bytes many times."
? ""
? "  A view is a WINDOW, not a copy: it stays valid only while its buffer"
? "  is alive. RppView holds a reference to its owner for exactly that"
? "  reason -- so the bytes cannot be freed underneath it -- which is the"
? "  F-22 lesson applied at the API boundary."
? ""
? "  And a payload handler that needs a real Ring string must call Str()"
? "  and pay the copy. The saving is in NOT needing one."
? ""

# leave nothing behind
try  remove(cFile)  catch  ? "  (note: could not remove " + cFile + ")"  done

? "EXAMPLE 05 OK"

### =====================================================================

func RawWay cFile, nRecs, nPay
    # Idiomatic Ring. read() gives one big string; every field is a substr,
    # and every substr copies the whole string.
    cData = read(cFile)
    nAcc = 0
    nOff = 0
    for i = 1 to nRecs
        nLen = bytes2int(substr(cData, nOff + 1, 4))
        cPayload = substr(cData, nOff + 5, nLen)
        nAcc += HandleRaw(cPayload)
        nOff += 4 + nLen
    next
    return nAcc

func HandleRaw cPayload
    # takes a STRING -- which was copied out of the file to get here
    return ascii(cPayload[1]) + ascii(cPayload[len(cPayload)]) * 3 + len(cPayload)

func RppWay cFile, nRecs, nPay, nBytes
    # LoadFile puts the bytes in a buffer that owns them. View() hands out a
    # window over a region without copying, and the window is an OBJECT, so
    # passing it to the handler costs a reference (example 02).
    oBuf = new RppBuffer(nBytes)
    oBuf.LoadFile(cFile)

    nAcc = 0
    nOff = 0
    for i = 1 to nRecs
        nLen = oBuf.PeekInt32(nOff)
        oView = oBuf.View(nOff + 4, nLen)
        nAcc += HandleView(oView)
        nOff += 4 + nLen
    next
    return nAcc

func HandleView oView
    # takes a WINDOW -- no bytes were copied to get here
    return oView.Byte(0) + oView.Byte(oView.Size() - 1) * 3 + oView.Size()

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
