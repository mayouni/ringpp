# Two Qt requests from 2020, both acknowledged, both still unwrapped on
# Ring 1.27 -- and the second one's code already ships with Ring.
#
#     ring qt_unwrapped.ring
#
#   QStringView          requested Jul 2020  "Yes, Added to the to-do list"
#   Qt State Machine API requested Jun 2020  "I will add them in the future :D"
#
# RingQt wraps 533 classes across 22 modules, so this is not a
# productivity problem. The difficulty is that WHICH 533 is decided in
# one place, and a user's own requirement has no route into that
# decision beyond asking and waiting.

load "guilib.ring"

aWanted = [
    "QStringView",
    "QStateMachine", "QState", "QFinalState",
    "QSignalTransition", "QHistoryState"
]

? "class                  reachable from Ring?"
? "-------------------------------------------"
for cName in aWanted
    cCode = 'o = new ' + cName + '()'
    try
        eval(cCode)
        ? "  " + cName + "  -- available"
    catch
        ? "  " + cName + "  -- NOT wrapped"
    done
next

? ""
? "Every state-machine class above is present in Qt5Core.dll (5.7 MB),"
? "which Ring ships in bin/ and RingQt already links. The binary is on"
? "disk; only the .cf declarations are missing."
