# Ring++ example 09, the THIRD renderer: the same window in a BROWSER.
#
# Contract 5.1 promises terminal AND browser from the one binary, and 7.2
# judges a renderer by the MODEL it leaves. This is the same tree and the
# same session, in a browser's own event vocabulary:
#
#   the terminal, as LINES      "amina", ""            (Ring 1.27)
#   the terminal, as KEYS       a m i n a <enter> ...  (Ring++)
#   the browser, as CONTROLS    set name, press OK     (either)
#
# Three input vocabularies, one model, byte for byte. That is the whole
# claim, and it is checked rather than asserted.
#
# THE SOCKET IS NOT HERE YET: this is the renderer's model half, gateable
# without a browser exactly as the keystroke renderer was gateable without
# a console. RppWebHtml() draws the frame the socket will serve.
#
#   Run it:  ring examples/09-a-window-in-the-terminal/web.ring

load "../../rpp/tui.ring"

$ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])

$RppWeb = [ [ :set, :name, "amina" ], [ :press, "OK" ] ]
$m = RunWeb($ui)
? "hello " + $m[:name]
? "serial: " + RppSerialise($m, $RppEvents)

# the frame the socket will serve, so a change to it is visible in review
? ""
? RppWebHtml($ui, $m)
? "WEB DONE"
