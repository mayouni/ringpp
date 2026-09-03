# Ring++ example 14 -- a handler that runs in place
#
# THE TASK: the callback form of Run (contract §4). Run(tree) returns when
# the window closes and the program acts afterwards; RunOn(tree, handler)
# calls the handler AS EACH EVENT HAPPENS, while the window is still open.
# The handler can answer in the status line and can close the window.
#
# WHAT A HANDLER MAY USE: GLOBALS, AND NOTHING ELSE. Measured on both
# runtimes on 2026-09-03 --
#
#   call f(...) on a function value        works on both
#   the handler sees GLOBALS               works on both
#   the handler sees the DEFINER'S LOCALS  Ring++ yes, Ring 1.27 R24
#
# -- so Ring++ is the more capable runtime here, and the contract takes
# the INTERSECTION: a handler reads $RppModel, writes its own globals, and
# says what it wants shown with RppSay(). A handler that closes over a
# local of the function that defined it runs on Ring++ and NOT on Ring
# 1.27, and §4 now says so.
#
# THE HANDLER IS A FUNCTION VALUE, not a name: Ring has no way to pass a
# NAMED function as a value, and an anonymous function called with `call`
# is what both runtimes agree on.
#
# Run it:  ring examples/14-a-handler-in-place/example.ring

load "../../ringpp.ring"

? "Ring++ example 14 -- a handler that runs in place"
? copy("-", 58)
? ""

$log = ""          # the handler's own record: globals are all it may use
$files = [ "notes.ring", "main.ring", "test.ring" ]

$OnEvent = func cKind, cName, vVal {
	if cKind = :change
		$log += "change:" + cName + "=" + vVal + "|"
		RppSay("noted " + cName)
	but cKind = :click
		# a click carries the item in the NAME slot and "" as its value --
		# the transcripts have always read click,OK, -- so cName it is
		$log += "click:" + cName + "|"
		if cName = "Open"
			# reading the LIVE model, mid-run
			RppSay("opening " + $RppModel[:file])
		ok
		return :close
	ok
	return ""
}

ui = Window("Open a file", [
	Label("File"),
	Choice(:file, $files),
	Entry(:why),
	Menu(:cmd, [ "Open", "Cancel" ]),
	Status("waiting") ])

$RppKeys = [ "2", "because", "1" ]
m = RunOn(ui, $OnEvent)

? ""
? "handler log: " + $log

### ---------------------------------------------------------------- the gate

# 1. the handler ran on every event, in order, while the window was open
cWant = "change:file=main.ring|change:why=because|change:cmd=Open|click:Open|"
if $log != cWant
	raise("HANDLER LOG WRONG:" + nl + "  got  " + $log + nl + "  want " + cWant)
ok

# 2. the handler CLOSED the window on the click, so no :submit was ever
#    fired -- the window stopped where the handler said, not at the end
aE = $RppEvents
if aE[len(aE)][1] != "close"
	raise("LAST EVENT SHOULD BE close, got " + aE[len(aE)][1])
ok
for e in aE
	if e[1] = "submit"
		raise("SUBMIT FIRED: the handler asked to close before it")
	ok
next

# 3. the handler read the live model DURING the run, not after
if substr($log, "main.ring") = 0
	raise("HANDLER DID NOT SEE THE MODEL")
ok

# 4. the same session twice, byte-identical
cA = RppSerialise(m, aE)
$log = ""
$RppKeys = [ "2", "because", "1" ]
m2 = RunOn(ui, $OnEvent)
cB = RppSerialise(m2, $RppEvents)
? "serial: " + cA
nSame = 0
if cA = cB
	nSame = 1
ok
? ""
? "identical output : " + nSame
if nSame = 0
	raise("TWO RUNS DIFFER: [" + cA + "] vs [" + cB + "]")
ok

? "events   : " + len(aE) + "  (3 changes, a click, a close -- no submit)"
? ""
? "EXAMPLE 14 OK"
