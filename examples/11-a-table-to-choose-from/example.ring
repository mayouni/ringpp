# Ring++ example 11 -- a table to choose from, from a widget tree
#
# THE TASK: a table of rows, one selected. The model holds the selected
# row NUMBER; a digit picks it. The keystroke renderer takes the same
# digit as a key, so a line "2" here and a key "2" under RunKeys leave the
# same model -- contract gate 7.2, a third tree.
#
# THE TABLE IS MINIMAL ON PURPOSE. Softanza's Show() already draws a rich
# table -- rounded box, aligned numbers -- and the contract asked whether
# the renderer should call that or own its own. Commitment #1 answers it:
# rpp/tui.ring is dependency-free and cannot load Softanza, so it owns a
# plain ASCII table, and the rich one is a Softanza-backed renderer on the
# same tree. This example draws the dependency-free one.
#
# Run it:  ring examples/11-a-table-to-choose-from/example.ring

load "../../ringpp.ring"

? "Ring++ example 11 -- a table to choose from"
? copy("-", 58)
? ""

ui = Window("Pick a city", [
	Label("Cities"),
	Table(:city, [ "name", "country" ], [
		[ "Cairo",  "Egypt" ],
		[ "Tunis",  "Tunisia" ],
		[ "Niamey", "Niger" ] ]),
	Button("OK", :submit) ])
$RppKeys = [ "3", "" ]
m = Run(ui)
? "picked row " + m[:city]

### ---------------------------------------------------------------- the gate

# 1. the model holds the row number that was typed
if m[:city] != 3
	raise("MODEL MISMATCH: " + RppSerialise(m, $RppEvents))
ok
aE = $RppEvents

# 2. three events: a change to row 3, a click, a submit
if len(aE) != 3
	raise("EVENT COUNT: expected 3, got " + len(aE))
ok
if aE[1][1] != "change" or aE[1][2] != "city" or aE[1][3] != 3
	raise("EVENT 1 wrong: " + aE[1][1] + " " + aE[1][2] + " " + aE[1][3])
ok
if aE[2][1] != "click" or aE[3][1] != "submit"
	raise("EVENT 2/3 wrong: " + aE[2][1] + " " + aE[3][1])
ok

# 3. the 7.2 harness: the same session twice, byte-identical
$RppKeys = [ "3", "" ]
m2 = Run(ui)
cA = RppSerialise(m, aE)
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

? "events   : " + len(aE) + "  (change, click, submit)"
? "model    : city row " + m[:city]
? ""
? "EXAMPLE 11 OK"
