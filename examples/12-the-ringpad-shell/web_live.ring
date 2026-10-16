# RingPad's shell in a BROWSER, live. Ring++ only.
#
#   Run it:   rnxc exec examples/12-the-ringpad-shell/web_live.ring
#   Open it:  http://127.0.0.1:8773
#
# The SAME loop as the terminal shell: choose a command, the program acts,
# the next screen is drawn. Each menu item is a button; choosing one ends
# the screen, and the browser is sent back for the next by a redirect. The
# listener stays open across screens; Quit closes it with a last page.
#
# This is the example F-53 blocked: the loop tripped a refcount underflow
# until an unresolved identifier stopped being classified as an int.
#
# Open a file, type in the editor, Save, edit again, Undo, then Quit.

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
$store = []

$log = ShellSession()
? ""
? "session over"

func ShellSession()
	$store = [ [ "notes.ring", [ "# notes", "" ] ], [ "main.ring", [ "? 'hello'" ] ], [ "test.ring", [ "" ] ] ]
	cLog = ""
	cStatus = "ready"
	aDoc = [ [ "" ], 1, 1 ]
	aHist = []
	cFile = ""
	while 1
		ui = Window("RingPad", [
			Label("File"),
			With(Choice(:file, $files), cFile),
			Label("Editor"),
			TextWith(:doc, aDoc),
			Menu(:cmd, [ "Open", "Save", "Undo", "Quit" ]),
			Status(cStatus) ])

		m = RunWebLive(ui, 8773)
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
			RppWebBye("RingPad", "closed -- " + cStatus)
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
