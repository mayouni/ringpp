# Ring++ example 09, the SECOND renderer: the same window driven by KEYS.
#
# Runs on Ring++ only -- it calls the four console builtins -- and it is
# the other half of contract gate 7.2: two renderers fed the same session
# must leave byte-identical model state. bench/tui72.py in rnx-spike runs
# example.ring on Ring 1.27 (the line renderer, "amina" then Enter) and
# this file on Ring++ (the keystroke renderer, a m i n a Enter Enter),
# and compares the two `serial:` lines byte for byte.
#
# Scripted, so it runs unattended and touches no console. To drive it
# live on your own keyboard, empty $RppKeys and run it with rnxc exec.
#
#   Run it:  rnxc exec examples/09-a-window-in-the-terminal/keys.ring

load "../../rpp/tui.ring"

$ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])
$RppKeys = [ "a", "m", "i", "n", "a", "<enter>", "<enter>" ]
$m = RunKeys($ui)
? "hello " + $m[:name]
? "serial: " + RppSerialise($m, $RppEvents)
? "KEYS DONE"
