# Ring++ example 15, the THIRD renderer: the same row in a BROWSER.
# A Row is a <div>; the controls inside it are the same controls, with the
# same names, so the form that comes back is the same form.
#
#   Run it:  ring examples/15-a-row-of-buttons/web.ring

load "../../rpp/tui.ring"

$ui = Window("Confirm", [
	Label("Name"),
	Entry(:name),
	Row([ Button("OK", :submit), Button("Cancel", :close) ]) ])

$RppWeb = [ [ :set, :name, "amina" ], [ :press, "OK" ] ]
$m = RunWeb($ui)
? "hello " + $m[:name]
? "serial: " + RppSerialise($m, $RppEvents)
? ""
? RppWebHtml($ui, $m)
? "WEB DONE"
