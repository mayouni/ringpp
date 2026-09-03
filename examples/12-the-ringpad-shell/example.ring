# Ring++ example 12 -- RingPad's shell, with its real editor and an Undo
#
# THE TASK: the forcing application for the whole contract, running its
# real editor under a gate. A file list, a `Text` that carries its
# document from screen to screen, a menu -- Open, Save, Undo, Quit -- and
# a status line, looping: choose a command, the program acts, the next
# screen is drawn.
#
# UNDO IS THE PROGRAM'S, NOT THE WIDGET'S (contract 6.3, made visible):
# the shell keeps a stack of previous document values and Undo restores
# one. History is history OF THE MODEL, so it is a command like any other,
# it is in the transcript, and the 7.2 gate judges it.
#
# NO CALLBACK, AND NONE NEEDED: Run returns when a menu item is chosen.
# The loop IS the application.
#
# Run it:  ring examples/12-the-ringpad-shell/example.ring

load "../../ringpp.ring"

? "Ring++ example 12 -- RingPad's shell"
? copy("-", 58)
? ""

$files = [ "notes.ring", "main.ring", "test.ring" ]
# born HERE, at the top level: on Ring 1.27 the $ prefix is a convention,
# and a name first assigned inside a function is a local of that
# function. Rule A is semantics on Ring++ and discipline on Ring.
$store = []

# the same session twice, for the runner's identical-output line:
#   screen 1  pick main.ring, type hello / world, Save
#   screen 2  pick main.ring, leave the editor as it is, Undo
#   screen 3  pick main.ring, leave it, Quit
aSession = [ "2", "hello", "world", "", "2",   "2", "", "3",   "2", "", "4" ]
$RppKeys = aSession
cA = ShellSession()
$RppKeys = aSession
cB = ShellSession()

? ""
? "serial: " + cA

### ---------------------------------------------------------------- the gate

# 1. the transcript, worked out by hand: three screens, and the third
#    shows the document that Undo restored -- one empty line at 1:1
cS1 = "model:file=main.ring|doc=2,6,hello" + $RppBsN + "world|cmd=Save|events:change,file,main.ring|change,doc,2,6,hello" + $RppBsN + "world|change,cmd,Save|click,Save,|submit,,|#"
cS2 = "model:file=main.ring|doc=2,6,hello" + $RppBsN + "world|cmd=Undo|events:change,file,main.ring|change,doc,2,6,hello" + $RppBsN + "world|change,cmd,Undo|click,Undo,|submit,,|#"
cS3 = "model:file=main.ring|doc=1,1,|cmd=Quit|events:change,file,main.ring|change,doc,1,1,|change,cmd,Quit|click,Quit,|submit,,|#"
if cA != cS1 + cS2 + cS3
	raise("TRANSCRIPT WRONG:" + nl + "  got  " + cA + nl + "  want " + cS1 + cS2 + cS3)
ok

# 2. Save reached the store, and Undo did not touch what was saved
if len($store["main.ring"]) != 2 or $store["main.ring"][2] != "world"
	raise("STORE WRONG: " + len($store["main.ring"]) + " line(s)")
ok

# 3. the same session twice is byte-identical
nSame = 0
if cA = cB
	nSame = 1
ok
? ""
? "identical output : " + nSame
if nSame = 0
	raise("TWO SESSIONS DIFFER")
ok

? "screens  : 3  (Save, Undo, Quit); the document Undo restored is one empty line"
? ""
? "EXAMPLE 12 OK"

### ---------------------------------------------------------------- the shell

### One whole session. The document lives in aDoc between screens; every
### change to it pushes the previous value on aHist, and Undo pops one.
### Returns the transcript: every screen's model and events, in order.
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
		m = Run(ui)
		cLog += RppSerialise(m, $RppEvents) + "#"

		# the edit this screen made, if any, goes on the history first
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

### A copy without its last item. Rebuilt rather than deleted in place, so
### it asks nothing of either runtime beyond append.
func DropLast(aL)
	aNew = []
	nLast = len(aL) - 1
	for i = 1 to nLast
		aNew + aL[i]
	next
	return aNew
