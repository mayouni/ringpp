# RingPad's shell with its real editor, LIVE: your keyboard, your console.
#
#   Run it:  rnxc exec examples/12-the-ringpad-shell/keys_live.ring
#
# Up and Down move within the file list and the menu; in the editor the
# arrows move the cursor, Enter breaks the line, Tab leaves it. Enter on
# a menu item ACTIVATES it: Open loads the chosen file's lines, Save
# stores yours, Undo restores the document as it was before your last
# change -- history the program keeps, not the widget (contract 6.3) --
# and Quit ends the session. The document carries from screen to screen.

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
# born HERE, at the top level: on Ring 1.27 the $ prefix is a convention,
# and a name first assigned inside a function is a local of that
# function. Rule A is semantics on Ring++ and discipline on Ring.
$store = []
$log = ShellSession()
? "session over"

func ShellSession()
	$store = [ [ "notes.ring", [ "# notes", "" ] ], [ "main.ring", [ "? 'hello'" ] ], [ "test.ring", [ "" ] ] ]
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
		m = RunKeys(ui)
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
