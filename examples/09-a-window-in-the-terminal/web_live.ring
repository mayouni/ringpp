# The browser renderer, LIVE: the binary serves the page, your browser
# sends it back. Ring++ only -- web_serve/web_wait/web_done are builtins.
#
#   Run it:   rnxc exec examples/09-a-window-in-the-terminal/web_live.ring
#   Open it:  http://127.0.0.1:8770
#
# Type a name and press OK. The page is the same tree the terminal
# renderers draw, and the model it leaves is the same model -- which is
# what gate 7.2 checks on every run, without a browser.

load "../../rpp/tui.ring"

$ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])

$m = RunWebLive($ui, 8770)
? ""
? "hello " + $m[:name]
? "serial: " + RppSerialise($m, $RppEvents)
