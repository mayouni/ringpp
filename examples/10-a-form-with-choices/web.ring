# Ring++ example 10, the THIRD renderer: the same form in a BROWSER.
# The same session as example.ring's lines and keys.ring's keys, in a
# browser's vocabulary -- a control SET to a value, a button PRESSED.
#
#   Run it:  ring examples/10-a-form-with-choices/web.ring

load "../../rpp/tui.ring"

$ui = Window("Sign up", [
	Label("Name"),
	Entry(:name),
	Checkbox(:remember, "Remember me"),
	Radio(:color, [ "Red", "Green", "Blue" ]),
	Choice(:city, [ "Cairo", "Tunis", "Niamey" ]),
	Button("OK", :submit) ])

$RppWeb = [ [ :set, :name, "amina" ],
            [ :set, :remember, 1 ],
            [ :set, :color, "Green" ],
            [ :set, :city, "Niamey" ],
            [ :press, "OK" ] ]
$m = RunWeb($ui)
? "hello " + $m[:name] + " from " + $m[:city]
? "serial: " + RppSerialise($m, $RppEvents)
? "WEB DONE"
