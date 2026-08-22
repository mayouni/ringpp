# Fixture for the T1 lint gate. Self-contained ON PURPOSE.
#
# This gate used to point at D:\GitHub\stzlib\...\stkPointer.ring, which
# made Ring++'s own test suite unrunnable by anyone who does not also have
# Softanza checked out next to it. Ring++ is an independent project and a
# Ring package; its gates may not depend on another repository.
#
# The stzlib corpus check still runs when that tree happens to be present,
# as an EXTRA -- and prints SKIP with the reason when it is not, because a
# gate quietly not run is a green nobody earned.
#
# Every defect below is deliberate. Do not "fix" this file.

load "../../ringpp.ring"

func DeadLowLevelPath
    # rpp/varptr-unknown-name: there is no variable `cBufferData` anywhere
    # in this file -- the local is `_cBufferData_`. varptr resolves the name
    # at run time, raises Error (R6), and the surrounding try/catch swallows
    # it, leaving a NULL pointer and a dead branch that never runs again.
    _cBufferData_ = space(64)
    pLow = NULL
    try
        pLow = varptr(:cBufferData, "char *")
    catch
        pLow = NULL
    done
    return pLow

func LeakyHandler
    # rpp/empty-catch: Ring pops the raised value only when something in the
    # handler consumes it. ~1003 of these is Error (R4) Stack Overflow from
    # code with no recursion at all.
    for i = 1 to 3
        try
            raise("boom")
        catch
        done
    next

func SlowScan cBig
    # rpp/substr-in-loop: substr copies the WHOLE string before slicing.
    nAcc = 0
    for i = 1 to 10
        nAcc += len(substr(cBig, i, 4))
    next
    return nAcc
