# Ring++ example 13, the THIRD renderer: the same editor in a BROWSER.
# A browser sends a textarea as its LINES; the cursor lands after the last
# character of the last line, which is the rule the line renderer uses too
# (contract 6.1/6.4), so all three leave the same [ lines, row, col ].
#
#   Run it:  ring examples/13-a-text-to-edit/web.ring

load "../../rpp/tui.ring"

$ui = Window("Edit", [
	Label("Notes"),
	Text(:doc),
	Button("OK", :submit) ])

$RppWeb = [ [ :set, :doc, [ "abc", "def" ] ], [ :press, "OK" ] ]
$m = RunWeb($ui)
$aDoc = $m[:doc]
? "lines: " + len($aDoc[1]) + "   cursor: " + $aDoc[2] + ":" + $aDoc[3]
? "serial: " + RppSerialise($m, $RppEvents)
? "WEB DONE"
