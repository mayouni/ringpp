# Ring's named constants are ordinary variables. All six of them.
#
#     ring mutable_constants.ring
#
# TRUE/FALSE/NULL are the ones usually named. NL is the dangerous one:
# it is in the output path of essentially every Ring program ever
# written, and because names fold case, an ordinary local called `nl`
# is the same variable.

? "--- before"
? "TRUE=" + TRUE + " FALSE=" + FALSE + " len(NL)=" + len(NL) + " len(TAB)=" + len(TAB)

TRUE = 0
FALSE = 1
NULL = "i am not null"
NL = "XX"
TAB = "<tab-was-here>"
CR = "<cr-was-here>"

? "--- after"
? "TRUE=" + TRUE + " FALSE=" + FALSE
if TRUE ? "  if TRUE taken" else ? "  if TRUE NOT taken -- control flow inverted" ok
? "  isNull(NULL) = " + isNull(NULL)
? "  a + NL + b   = " + ("a" + NL + "b")
? "  TAB is now   = [" + TAB + "]"
? "  CR is now    = [" + CR + "]"

# --- and the lexical hazard, from the July 2024 group thread
? "--- a bare colon takes the next word"
? : anything
x = : hello
? "  x = [" + x + "]  type " + type(x)
