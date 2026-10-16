# A Softanza-shaped bridge on Ring++, checked.
#
# bench/bridge_demo.zig is written exactly as engine/src/ring_bridge_*.zig
# is written -- the same R.* calls, the same Reg table, the same
# registerAll -- and differs from a real bridge in one line: it imports
# ring_api_rpp.zig instead of ring_api.zig. Every answer below is checked
# against the same computation in plain Ring, so this file fails loudly
# rather than printing something plausible.
#
#     rnxc exec bench/bridge.ring     -> BRIDGE OK

$nBad = 0

if LoadLib("rppbridge.dll") = NULL
	? "BRIDGE FAIL: rppbridge.dll did not load"
	bye
ok

# -- scalars
Same("add", BridgeAdd(2, 40), 42)
Same("upper", BridgeUpper("ring plus plus"), "RING PLUS PLUS")

# A bridge that answers out of a STACK buffer -- the shape every engine
# bridge uses, and the one this backend got wrong until 2026-09-15: it kept
# the pointer and let the VM copy after the bridge had returned, so the
# answer came back with its head overwritten and its tail intact. The other
# string probes here all answer out of a static buffer, which is why they
# could never see it. Three calls, because the corruption only shows once
# something else has used the stack the buffer was in.
cStack1 = BridgeStackStr(48)
cStack2 = BridgeStackStr(48)
Same("a stack buffer survives the return", cStack1, "0123456789abcdef0123456789abcdef0123456789abcdef")
Same("...and is not disturbed by the next call", cStack2, cStack1)
Same("...nor by building a string around it", "x" + cStack1 + "y",
     "x0123456789abcdef0123456789abcdef0123456789abcdefy")

# -- handles: the protocol Softanza uses everywhere
$h = BridgeCounterNew(10)
BridgeCounterBump($h, 5)
Same("handle", BridgeCounterBump($h, 27), 42)
BridgeCounterFree($h)

# -- reading a list, nested, through Ring's item protocol
$a = [1, 2, [3, 4, [5]], 6]
Same("list sum", BridgeListSum($a), 21)
Same("list chars", BridgeListChars(["ring", "plus", "plus"]), 12)

# -- building a list, with a sublist made inside its parent
$m = BridgeListMake(3)
Same("made len", len($m), 3)
Same("made [1]", $m[1], 3)
Same("made [2]", $m[2], "3 items")
Same("made [3] len", len($m[3]), 3)
Same("made [3][2]", $m[3][2], 2)

# -- a list in and a list out
$u = BridgeListUpper(["ring", "plus"])
Same("upper len", len($u), 2)
Same("upper [1]", $u[1], "RING")
Same("upper [2]", $u[2], "PLUS")

# -- an error a bridge RAISES is a Ring error: caught by a try, its text as
#    the bridge wrote it, and the program runs on (F-103). It ended the
#    process with `Error: native call failed` until 2026-10-09, so this line
#    and every one after it never printed.
cErr = "nothing raised"
try
	BridgeUpper(5)
catch
	cErr = cCatchError
done
Same("a bridge's error is caught", cErr, "BridgeUpper expects a string")
Same("...and the bridge still answers", BridgeUpper("after"), "AFTER")

# -- the answers again, computed in plain Ring, so the checks above are
#    checked too: a bridge that returned nothing would match nothing.
$nSum = 0
for i = 1 to 6
	$nSum = $nSum + i
next
Same("ring's own sum", $nSum, 21)

if $nBad = 0
	? "BRIDGE OK"
else
	? "BRIDGE FAILED -- " + $nBad + " wrong"
ok

func Same(cWhat, xGot, xWant)
	if "" + xGot = "" + xWant
		? "  ok   " + cWhat + " = " + xGot
	else
		$nBad = $nBad + 1
		? "  FAIL " + cWhat + ": got " + xGot + ", want " + xWant
	ok
