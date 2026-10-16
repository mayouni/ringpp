# `isPointer` answers for ONE thing: a loaded native library.
#
# Measured on Ring 1.27 WITH Softanza's real engine, because the rows that
# matter need real handles:
#
#     $pStzGraphHandle (from LoadLib)   type DLL      isPointer 1
#     o.Engine()       (engine handle)  type NUMBER   isPointer 0
#     5, 0, "abc", "", [1,2], NULL                    isPointer 0
#
# So it is not "is this a handle" -- an ENGINE handle is a number on Ring
# exactly as it is here, and isPointer says no to it. It is "is this a
# library that LoadLib opened".
#
# Ring++ had no isPointer at all: `Calling Function without definition:
# ispointer`, which killed system/service_delivery. The temptation was to
# answer it truthily -- anything non-NULL is a pointer -- and every row in
# the first block below is a row that would have made wrong. The other
# temptation was a faithful type test over a LoadLib that returned the
# INTEGER 1, which answers FALSE for a library that HAS loaded, and
# stzGraph._EngineAvailable() would then have switched the whole engine
# graph path off in silence.
#
# LoadLib answers a DLL value now, as Ring's does. This file pins the half
# that needs no engine; the other half is measured against the estate, where
# both runtimes report type DLL, isPointer 1, and HasEngine 1.

? "-- nothing ordinary is a pointer --"
? "  isPointer(5)       " + isPointer(5)
? "  isPointer(0)       " + isPointer(0)
? "  isPointer(1)       " + isPointer(1)
? "  isPointer(-1)      " + isPointer(-1)
? "  isPointer(1.5)     " + isPointer(1.5)
? "  isPointer('abc')   " + isPointer("abc")
? "  isPointer('')      " + isPointer("")
? "  isPointer('1')     " + isPointer("1")
? "  isPointer([])      " + isPointer([])
? "  isPointer([1,2])   " + isPointer([1, 2])
? "  isPointer(NULL)    " + isPointer(NULL)
? "  isPointer(TRUE)    " + isPointer(TRUE)

? ""
? "-- nor an object, nor a function --"
o = new T
? "  isPointer(object)  " + isPointer(o)
? "  isObject(object)   " + isObject(o)

? ""
? "-- LoadLib either answers a library or RAISES, and both raises are caught --"
try
    p = LoadLib("no_such_library_at_all.dll")
    ? "  returned: " + isPointer(p)
catch
    ? "  caught: " + cCatchError
done
? "  still running"

# The OTHER failure -- a library that opens but carries the wrong init
# function -- is R46 on Ring and R46 here, and it is not probed because the
# two runtimes look for different symbols: Ring wants `ringlib_init`, this
# VM wants `rpp_init`, so the same file fails on one and loads on the other.
# That is the single irreducible difference between them, and the message
# names the symbol the runtime actually looked for.

class T
    n
