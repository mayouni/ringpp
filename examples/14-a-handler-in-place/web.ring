# Ring++ example 14, the THIRD renderer: the same handler in a BROWSER.
# The SAME handler function, the same session in a browser's vocabulary,
# and the same transcript -- including the early :close the handler asks
# for on the click, so no :submit is ever fired here either.
#
#   Run it:  ring examples/14-a-handler-in-place/web.ring

load "../../rpp/tui.ring"

$log = ""
$files = [ "notes.ring", "main.ring", "test.ring" ]

$OnEvent = func cKind, cName, vVal {
	if cKind = :change
		$log += "change:" + cName + "=" + vVal + "|"
		RppSay("noted " + cName)
	but cKind = :click
		$log += "click:" + cName + "|"
		if cName = "Open"
			RppSay("opening " + $RppModel[:file])
		ok
		return :close
	ok
	return ""
}

$ui = Window("Open a file", [
	Label("File"),
	Choice(:file, $files),
	Entry(:why),
	Menu(:cmd, [ "Open", "Cancel" ]),
	Status("waiting") ])

$RppWeb = [ [ :set, :file, "main.ring" ],
            [ :set, :why, "because" ],
            [ :pick, :cmd, "Open" ] ]
$m = RunWebOn($ui, $OnEvent)
? "handler log: " + $log
? "serial: " + RppSerialise($m, $RppEvents)
? "WEB DONE"
