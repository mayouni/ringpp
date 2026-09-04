# Ring++ example 12, the THIRD renderer: RingPad's shell in a BROWSER.
#
# The same three screens -- save main.ring, undo, quit -- in a browser's
# vocabulary, and the whole transcript must be byte-identical to the
# lines and the keys. A menu item PICKED ends the screen exactly as
# choosing one does under the other two, so the shell loop below is the
# same loop, with RunWeb where the others call Run and RunKeys.
#
#   Run it:  ring examples/12-the-ringpad-shell/web.ring

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
# born at the top level: on Ring 1.27 a $name first assigned inside a
# function is a LOCAL of it. Rule A is semantics on Ring++, discipline here.
$store = []
$screen = 0

$log = ShellSession()
? ""
? "serial: " + $log
? "WEB DONE"

func ShellSession()
	$store = [ [ "notes.ring", [ "" ] ], [ "main.ring", [ "" ] ], [ "test.ring", [ "" ] ] ]
	$screen = 0
	cLog = ""
	cStatus = "ready"
	aDoc = [ [ "" ], 1, 1 ]
	aHist = []
	while 1
		ui = Window("RingPad", [
			Label("File"),
			Choice(:file, $files),
			Label("Editor"),
			TextWith(:doc, aDoc),
			Menu(:cmd, [ "Open", "Save", "Undo", "Quit" ]),
			Status(cStatus) ])

		$screen++
		if $screen = 1
			$RppWeb = [ [ :set, :file, "main.ring" ],
			            [ :set, :doc, [ "hello", "world" ] ],
			            [ :pick, :cmd, "Save" ] ]
		but $screen = 2
			$RppWeb = [ [ :set, :file, "main.ring" ],
			            [ :set, :doc, [ "hello", "world" ] ],
			            [ :pick, :cmd, "Undo" ] ]
		else
			$RppWeb = [ [ :set, :file, "main.ring" ],
			            [ :set, :doc, [ "" ] ],
			            [ :pick, :cmd, "Quit" ] ]
		ok

		m = RunWeb(ui)
		cLog += RppSerialise(m, $RppEvents) + "#"

		if RppTuiSerVal(m[:doc]) != RppTuiSerVal(aDoc)
			aHist + aDoc
			aDoc = m[:doc]
		ok

		cCmd = m[:cmd]
		cFile = m[:file]
		if cCmd = "Open"
			aHist + aDoc
			aDoc = [ $store[cFile], 1, 1 ]
			cStatus = "opened " + cFile + " (" + len(aDoc[1]) + " lines)"
		but cCmd = "Save"
			$store[cFile] = aDoc[1]
			cStatus = "saved " + cFile + " (" + len(aDoc[1]) + " lines)"
		but cCmd = "Undo"
			if len(aHist) > 0
				aDoc = aHist[len(aHist)]
				aHist = DropLast(aHist)
				cStatus = "undo: " + len(aHist) + " left"
			else
				cStatus = "nothing to undo"
			ok
		but cCmd = "Quit"
			exit
		ok
	end
	return cLog

func DropLast(aL)
	aNew = []
	nLast = len(aL) - 1
	for i = 1 to nLast
		aNew + aL[i]
	next
	return aNew
