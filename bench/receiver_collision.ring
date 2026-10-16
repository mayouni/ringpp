# The R31 reproduction, and the two controls that explain it.
#
# Mansour's most confusing Ring surprise, unexplained for years: naming a
# variable with a name the class uses internally raises
#
#     Error (R31) : Trying to destroy the object using the self reference
#
# It is 2.7's ordinary outward write aimed at one particular variable.
# A method's bare assignment resolves outward to the caller's scope; when
# it lands on the variable holding the object whose method is running,
# Ring refuses rather than let the receiver be destroyed mid-call. The
# message describes Ring's internal defence, not the programmer's code,
# which is why it reads as inexplicable.
#
# Run each case on its own -- case A stops execution:
#
#     ring receiver_collision.ring A     -> R31, execution stops
#     ring receiver_collision.ring B     -> HELLO           (no collision)
#     ring receiver_collision.ring C     -> HELLO, then the caller's
#                                           object is now a STRING
#
# C is the dangerous one. A is loud; C is silent, and C is what ships.

cCase = "A"
if len(sysargv) >= 3 cCase = upper(sysargv[3]) ok

switch cCase
on "A"
    # the caller's variable IS the receiver, and the method uses that name
    oStr = new stzString("hello")
    ? oStr.Up()

on "B"
    # no collision: the method's name matches nothing in the caller
    oOther = new stzString("hello")
    ? oOther.Up()

on "C"
    # the name collides, but with a DIFFERENT object than the receiver
    oStr = new stzString("world")
    oRun = new stzString("hello")
    ? oRun.Up()
    ? "caller's oStr is now: " + type(oStr)   # STRING -- the object is gone
off

class stzString
    cContent = ""

    def init(pc)
        cContent = pc

    def Up()
        oStr = "shadow"
        return upper(cContent)
