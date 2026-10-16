# Calling a method a class does not have is an ORDINARY CATCHABLE ERROR on
# Ring, and the program carries on after the catch.
#
#     Error (R14) : Calling Method without definition: <name>
#
# The name comes back LOWER-CASED, as Ring prints it. Ring++ panicked and
# took the process down instead -- and four tests in the wide clock died
# that way, three of them while the estate was doing exactly what this file
# does: asking an object whether it answers to something, inside a try.
# blob_port, data_port and http_port went from dead to 53, 41 and 37
# assertions, all passing, on this change alone.

o = new T
? "-- caught, and the program goes on --"
try
    o.NoSuchMethod()
catch
    ? "  caught: " + cCatchError
done
? "  still running"

? ""
? "-- the name is lower-cased, whatever case it was written in --"
try  o.MiXeDcAsE()  catch ? "  caught: " + cCatchError done

? ""
? "-- arguments do not change the answer --"
try  o.AlsoMissing(1, 2, 3)  catch ? "  caught: " + cCatchError done

? ""
? "-- a method the class DOES have still runs --"
? "  real method: " + o.Real()

? ""
? "-- and a child sees its parent's methods, not a missing one --"
c = new U
? "  inherited: " + c.Real()
try  c.NotOnEither()  catch ? "  caught: " + cCatchError done

? ""
? "-- uncaught, it reports and stops, like any other error --"
o.LastOne()
? "unreachable"

class T
    def Real()
        return "ran"

class U from T
