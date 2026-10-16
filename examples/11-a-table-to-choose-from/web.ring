# Ring++ example 11, the THIRD renderer: the same table in a BROWSER.
# A browser reports the row that was chosen; the model holds its NUMBER,
# exactly as it does under the other two renderers.
#
#   Run it:  ring examples/11-a-table-to-choose-from/web.ring

load "../../rpp/tui.ring"

$ui = Window("Pick a city", [
	Label("Cities"),
	Table(:city, [ "name", "country" ], [
		[ "Cairo",  "Egypt" ],
		[ "Tunis",  "Tunisia" ],
		[ "Niamey", "Niger" ] ]),
	Button("OK", :submit) ])

$RppWeb = [ [ :set, :city, 3 ], [ :press, "OK" ] ]
$m = RunWeb($ui)
? "picked row " + $m[:city]
? "serial: " + RppSerialise($m, $RppEvents)
? "WEB DONE"
