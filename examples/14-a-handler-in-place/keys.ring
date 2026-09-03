# Ring++ example 14, the SECOND renderer: the same handler, driven by KEYS.
#
# Runs on Ring++ only. The other half of contract gate 7.2 for the
# callback form: the SAME handler function, the same session typed as
# keys, and the transcript must be byte-identical to example.ring's.
#
#   2 Enter                 pick main.ring from the file list
#   b e c a u s e Enter     type into the entry
#   Enter                   menu: activate Open (the first item)
#
# The handler returns :close on the click, so the window stops there and
# no :submit is ever fired -- on this renderer exactly as on the other.
#
#   Run it:  rnxc exec examples/14-a-handler-in-place/keys.ring

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

$RppKeys = [ "2", "<enter>", "b", "e", "c", "a", "u", "s", "e", "<enter>", "<enter>" ]
$m = RunKeysOn($ui, $OnEvent)
? ""
? "handler log: " + $log
? "serial: " + RppSerialise($m, $RppEvents)
? "KEYS DONE"
