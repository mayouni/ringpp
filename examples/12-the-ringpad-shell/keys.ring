# Ring++ example 12, the SECOND renderer: RingPad's shell driven by KEYS.
#
# Runs on Ring++ only. The other half of contract gate 7.2 for the shell:
# the same three screens typed as keys instead of lines, and the transcript
# of all three must be byte-identical to example.ring's.
#
#   screen 1:  2 Enter                    pick main.ring
#              h e l l o Enter w o r l d  type two lines into the editor
#              Tab                        leave the editor (Enter is a line break)
#              Down Enter                 menu: Open -> Save, activate
#   screen 2:  2 Enter, Tab               pick main.ring, leave the editor as it is
#              Down Down Enter            menu: -> Undo, activate
#   screen 3:  2 Enter, Tab               pick, leave
#              Down Down Down Enter       menu: -> Quit, activate
#
# The third screen shows the document Undo restored: one empty line. That
# is contract 6.3 under a gate -- history of the MODEL, kept by the
# program, in the transcript, judged byte for byte.
#
#   Run it:  rnxc exec examples/12-the-ringpad-shell/keys.ring

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
# born HERE, at the top level: on Ring 1.27 the $ prefix is a convention,
# and a name first assigned inside a function is a local of that
# function. Rule A is semantics on Ring++ and discipline on Ring.
$store = []

$RppKeys = [ "2", "<enter>", "h", "e", "l", "l", "o", "<enter>", "w", "o", "r", "l", "d", "<tab>", "<down>", "<enter>",
             "2", "<enter>", "<tab>", "<down>", "<down>", "<enter>",
             "2", "<enter>", "<tab>", "<down>", "<down>", "<down>", "<enter>" ]
$log = ShellSession()
? ""
? "serial: " + $log
? "SHELL DONE"

func ShellSession()
	$store = [ [ "notes.ring", [ "" ] ], [ "main.ring", [ "" ] ], [ "test.ring", [ "" ] ] ]
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
