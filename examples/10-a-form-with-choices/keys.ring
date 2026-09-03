# Ring++ example 10, the SECOND renderer: the same form driven by KEYS.
#
# Runs on Ring++ only. The other half of contract gate 7.2 for this tree:
# a m i n a Enter, y Enter, 2 Enter, 3 Enter, Enter -- and the serialised
# model + events must be byte-identical to example.ring's, which types the
# same session as LINES on Ring 1.27. rnx-spike's bench/tui72.py compares.
#
# Live: empty $RppKeys and run it with rnxc exec. Space toggles the check,
# a digit picks an option, Enter moves on, Esc closes.
#
#   Run it:  rnxc exec examples/10-a-form-with-choices/keys.ring

load "../../rpp/tui.ring"

$ui = Window("Sign up", [
	Label("Name"),
	Entry(:name),
	Checkbox(:remember, "Remember me"),
	Radio(:color, [ "Red", "Green", "Blue" ]),
	Choice(:city, [ "Cairo", "Tunis", "Niamey" ]),
	Button("OK", :submit) ])
$RppKeys = [ "a", "m", "i", "n", "a", "<enter>", "y", "<enter>", "2", "<enter>", "3", "<enter>", "<enter>" ]
$m = RunKeys($ui)
? "hello " + $m[:name] + " from " + $m[:city]
? "serial: " + RppSerialise($m, $RppEvents)
? "KEYS DONE"
