# Ring++ example 15, the SECOND renderer: the same row, driven by KEYS.
#
# The focus ring is FLAT even though the drawing is not: Tab and the
# arrows walk entry -> OK -> Cancel, and the row's line marks whichever
# of its children has the focus, where it sits.
#
#   Run it:  rnxc exec examples/15-a-row-of-buttons/keys.ring

load "../../rpp/tui.ring"

$ui = Window("Confirm", [
	Label("Name"),
	Entry(:name),
	Row([ Button("OK", :submit), Button("Cancel", :close) ]) ])

$RppKeys = [ "a", "m", "i", "n", "a", "<enter>", "<enter>" ]
$m = RunKeys($ui)
? "hello " + $m[:name]
? "serial: " + RppSerialise($m, $RppEvents)
? "KEYS DONE"
