# Ring++ example 07 -- running generated Ring safely
#
# THE TASK, which is ordinary once a program gets ambitious: run Ring code
# your program did not write. A rule from a config file. A formula a user
# typed. A template. Code your own generator emitted.
#
# THE OBVIOUS TOOL IS eval(), AND IT SHARES YOUR VARIABLES.
#
# eval() runs in the HOST's scope. Anything the snippet assigns lands in
# your program. A snippet that innocently uses `nTotal` overwrites YOUR
# nTotal, and nothing warns you -- not at parse time, not at run time, not
# in the result. The program simply continues with a different number.
#
# THIS EXAMPLE MEASURES NOTHING WORTH BRAGGING ABOUT. RppSandbox is about
# 1.75x SLOWER than eval, and it says so below. What it buys is that the
# snippet cannot reach you.
#
# WHAT RING++ DOES: ring_state_init() creates a REAL SECOND INTERPRETER --
# its own globals, its own functions, its own error state -- for about
# 0.35 ms (FINDINGS F-13). RppSandbox wraps it and closes the two traps
# that make the raw API hard to use (F-3).

load "../../ringpp.ring"

### ---------------------------------------------------------------- setup

nSnippets = 200
nReps     = 3

# The snippet a generator might plausibly emit. It uses `nTotal` and
# `cName` -- ordinary names, chosen by someone who has never seen your code.
cSnippet = "nTotal = 7 * 6" + nl + "cName = 'from the snippet'"

? "Ring++ example 07 -- running generated Ring safely"
? copy("-", 58)
? "snippets : " + nSnippets + " evaluations"
? "the code : nTotal = 7 * 6 ; cName = 'from the snippet'"
? ""

### ------------------------------------------- the isolation, demonstrated
#
# This is the point of the example. Everything below it is detail.

nTotal = 100
cName  = "HOST OWNS THIS"

eval(cSnippet)

bHostClobbered = (nTotal != 100 or cName != "HOST OWNS THIS")
? "with eval():"
? "  host nTotal is now : " + nTotal + "        (it was 100)"
? "  host cName is now  : " + cName + "   (it was HOST OWNS THIS)"
? "  host state damaged : " + bHostClobbered
? ""

# reset, then the same snippet through a sandbox
nTotal = 100
cName  = "HOST OWNS THIS"

oBox = RppSandbox()
oBox.Run(cSnippet)

bHostSafe = (nTotal = 100 and cName = "HOST OWNS THIS")
? "with RppSandbox():"
? "  host nTotal is now : " + nTotal + "        (untouched)"
? "  host cName is now  : " + cName + "   (untouched)"
? "  snippet's nTotal   : " + oBox.Var("nTotal") + "         (readable, over there)"
? "  host state safe    : " + bHostSafe
oBox.Free()
? ""

### -------------------------------------------- errors stay over there too

oBox2 = RppSandbox()
oBox2.Quiet()
oBox2.Run("this is not valid Ring at all {{{")
bSurvived = oBox2.IsOpen()
oBox2.Free()

? "a snippet that does not even parse:"
? "  host still running : " + bSurvived
? "  (eval() on the same text would raise into YOUR call stack)"
? ""

### ------------------------------------------------ correctness, then cost
#
# `identical output` here means both routes computed the same ANSWER --
# the sandbox is not allowed to be safe by being wrong.

nEval = 0
nBox  = 0

nRawBest = 0
for r = 1 to nReps
    nT = clock()
    nEval = EvalWay(cSnippet, nSnippets)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nRawBest
        nRawBest = nMs
    ok
next

nFreshBest = 0
for r = 1 to nReps
    nT = clock()
    nBox = BoxFreshWay(cSnippet, nSnippets)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nFreshBest
        nFreshBest = nMs
    ok
next

nReusedBest = 0
for r = 1 to nReps
    nT = clock()
    nBox2 = BoxReusedWay(cSnippet, nSnippets)
    nMs = (clock() - nT) / clockspersecond() * 1000
    if r = 1 or nMs < nReusedBest
        nReusedBest = nMs
    ok
next

bSame = (nEval = nBox) and (nBox = nBox2) and bHostSafe and bHostClobbered and bSurvived
? "identical output : " + bSame
if NOT bSame
    ? "  FAILED -- eval " + nEval + " | fresh " + nBox + " | reused " + nBox2
ok
? ""

### MEASURED TWICE, for the same reason as example 06: the first draft
### measured only the fresh-sandbox-per-snippet case, got 193x, and still
### called it "as expected" while citing F-13's 1.75x. Those are two
### different things, and the difference is the whole advice.

? "raw Ring        : " + RppMs(nRawBest) + "   (eval, in the host)"
? "Ring++          : " + RppMs(nReusedBest) + "   (ONE sandbox, reused)"
? "                  " + RppMs(nFreshBest) + "   (a FRESH sandbox per snippet)"
? ""
if nRawBest > 0
    ? "cost of containment : " + Round1(nReusedBest / nRawBest) + "x   when the sandbox is reused"
    ? "cost of creation    : " + Round1(nFreshBest / nRawBest) + "x   when it is not"
    ? ""
    ? "        The gap between those two lines is ring_state_init(), paid"
    ? "        " + nSnippets + " times instead of once. REUSE THE SANDBOX."
ok
? ""

### ------------------------------------------------------ the honest half

? "Where this LOSES:"
? "  Slower than eval either way -- see the two numbers above. If the"
? "  code is YOURS and you trust it, eval() is faster and simpler."
? ""
? "  The creation cost dominates, so REUSE ONE SANDBOX unless the"
? "  snippets must be isolated from each other as well as from you."
? ""
? "  Quiet() does not silence everything. A snippet that fails to PARSE"
? "  still prints its C18 from inside the sub-state -- you saw one above."
? "  ringvm_hideerrormsg(1) suppresses runtime errors, not the scanner."
? "  The host survives either way, which is the part that matters."
? ""
? "  A sandbox is NOT a security boundary. The snippet still runs with"
? "  your process's file and network access. It contains ACCIDENTS --"
? "  a name collision, a bad formula, a syntax error -- not attackers."
? ""
? "  Two traps the raw ring_state_* API has, closed here (FINDINGS F-3):"
? "    * findvar needs the name folded to lower case, or it silently misses"
? "    * absence is reported as the NUMBER 0, indistinguishable from a"
? "      variable holding 0 -- Var() raises instead"
? ""
? "EXAMPLE 07 OK"

### =====================================================================

func EvalWay cSnippet, nSnippets
    # eval() in the host. Fast, and it writes into whatever scope it lands in.
    nAcc = 0
    for i = 1 to nSnippets
        eval(cSnippet)
        nAcc += nTotal
    next
    return nAcc

func BoxFreshWay cSnippet, nSnippets
    # A fresh sub-state per snippet. The worst case -- and the shape you
    # genuinely need when the snippets must not see EACH OTHER either.
    nAcc = 0
    for i = 1 to nSnippets
        oB = RppSandbox()
        oB.Run(cSnippet)
        nAcc += oB.Var("nTotal")
        oB.Free()
    next
    return nAcc

func BoxReusedWay cSnippet, nSnippets
    # One sub-state, many Run() calls. The realistic shape, and the one
    # FINDINGS F-13's ~1.75x actually describes.
    nAcc = 0
    oB = RppSandbox()
    for i = 1 to nSnippets
        oB.Run(cSnippet)
        nAcc += oB.Var("nTotal")
    next
    oB.Free()
    return nAcc

func Round1 n
    return "" + (floor(n * 10) / 10)

func RppMs nMs
    if nMs < 1
        return "below the 1 ms timer floor"
    ok
    return "" + floor(nMs) + " ms"
