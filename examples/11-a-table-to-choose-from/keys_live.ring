# The table, LIVE: your keyboard, your console, Ring++ only.
#
#   Run it:  rnxc exec examples/11-a-table-to-choose-from/keys_live.ring
#
# Type a digit (1, 2 or 3) to select a city row -- the ">" marker jumps to
# it as you press. Enter leaves the table and moves to OK, Enter again
# submits, Esc closes. Runs in Windows Terminal and in a plain cmd.exe
# window alike, because tui_init() switches the console on from inside the
# binary.

load "../../rpp/tui.ring"

$ui = Window("Pick a city", [
	Label("Cities"),
	Table(:city, [ "name", "country" ], [
		[ "Cairo",  "Egypt" ],
		[ "Tunis",  "Tunisia" ],
		[ "Niamey", "Niger" ] ]),
	Button("OK", :submit) ])
$m = RunKeys($ui)
? "picked row " + $m[:city]
