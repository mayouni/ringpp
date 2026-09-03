# Ring++ example 11, the SECOND renderer: the same table driven by KEYS.
#
# Runs on Ring++ only. The other half of contract gate 7.2 for this tree:
# 3 Enter, Enter -- a digit selects the row, Enter leaves the table, Enter
# presses OK -- and the serialised model + events must be byte-identical
# to example.ring's, which types the same session as LINES on Ring 1.27.
#
# Live: empty $RppKeys and run it with rnxc exec. A digit picks a row,
# Enter moves on, Esc closes.
#
#   Run it:  rnxc exec examples/11-a-table-to-choose-from/keys.ring

load "../../rpp/tui.ring"

$ui = Window("Pick a city", [
	Label("Cities"),
	Table(:city, [ "name", "country" ], [
		[ "Cairo",  "Egypt" ],
		[ "Tunis",  "Tunisia" ],
		[ "Niamey", "Niger" ] ]),
	Button("OK", :submit) ])
$RppKeys = [ "<down>", "<down>", "<enter>", "<enter>" ]
$m = RunKeys($ui)
? "picked row " + $m[:city]
? "serial: " + RppSerialise($m, $RppEvents)
? "KEYS DONE"
