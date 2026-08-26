# The Ring program that runs inside the APK.
#
# Deliberately not a hello-world: it exercises the things a real program
# needs, so that a green screen on the phone means something. Lists,
# string building, a class with methods, file I/O into the app's own
# private directory, and Ring's own date/time.

? "Ring on Android"
? copy("=", 34)
? ""

# --- lists and string building -------------------------------------------
aRows = []
for i = 1 to 6
    aRows + ["item-" + i, i * i]
next

cReport = ""
for r in aRows
    cReport += r[1] + "  squared = " + r[2] + nl
next
? cReport

# --- a class with state ---------------------------------------------------
oAcc = new Accumulator
for r in aRows
    oAcc.Add(r[2])
next
? "sum of squares : " + oAcc.Total()
? "count          : " + oAcc.Count()
? ""

# --- file I/O, in the directory the app owns ------------------------------
cFile = "report.txt"
write(cFile, cReport)
cBack = read(cFile)
? "wrote and re-read : " + len(cBack) + " bytes"
? "round-trip exact  : " + (cBack = cReport)
? ""

# --- Ring's own runtime facts --------------------------------------------
? "date : " + date()
? "time : " + time()
? ""
? "-- the VM is a static musl build, no NDK, no Qt --"

class Accumulator
    nTotal = 0
    nCount = 0

    func Add nValue
        nTotal += nValue
        nCount++

    func Total
        return nTotal

    func Count
        return nCount
