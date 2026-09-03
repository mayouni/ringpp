# Ring++ example 12 -- RingPad's shell, from a widget tree
#
# THE TASK, and the reason it comes before the editor: RingPad is the
# forcing application for this whole contract, and its SHELL -- a file
# list, a menu, a status line -- can be built from widgets that exist,
# while its centre, a multi-line editor with a cursor and undo, is `Text`,
# the contract's named hard widget. Building the shell first makes the
# shell name exactly what Text must do, instead of guessing at it.
#
# THE EDITOR IS A PLACEHOLDER HERE, and says so on screen: a one-line
# Entry standing where Text will go. Everything around it is real.
#
# NO CALLBACK, AND NONE NEEDED. The contract sketches Run(ui, handler)
# (§4) and that is not built -- Ring 1.27's anonymous functions see only
# globals (charter §4e), so a handler is a decision, not a detail. A shell
# does not need one: Run returns when a menu item is chosen, the program
# acts on it and draws the next screen. The loop IS the application.
#
# Run it:  ring examples/12-the-ringpad-shell/example.ring

load "../../ringpp.ring"

? "Ring++ example 12 -- RingPad's shell"
? copy("-", 58)
? ""

$files = [ "notes.ring", "main.ring", "test.ring" ]

# the same session twice, for the runner's identical-output line
$RppKeys = [ "2", "hello", "2",   "1", "", "3" ]
cA = ShellSession()
$RppKeys = [ "2", "hello", "2",   "1", "", "3" ]
cB = ShellSession()

? ""
? "transcript: " + cA
? "serial: " + cA

### ---------------------------------------------------------------- the gate

# 1. the session did what the keys said: saved main.ring, then quit
if substr(cA, "cmd=Save") = 0 or substr(cA, "cmd=Quit") = 0
	raise("TRANSCRIPT MISSING A COMMAND: " + cA)
ok
if substr(cA, "file=main.ring") = 0
	raise("TRANSCRIPT MISSING THE FILE: " + cA)
ok
if substr(cA, "line=hello") = 0
	raise("TRANSCRIPT MISSING THE EDITED LINE: " + cA)
ok

# 2. a menu ends its screen with three events, in order
if substr(cA, "change,cmd,Save|click,Save,|submit,,|") = 0
	raise("MENU EVENT ORDER WRONG: " + cA)
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

? "screens  : 2  (Save, then Quit)"
? ""
? "EXAMPLE 12 OK"

### ---------------------------------------------------------------- the shell

### One whole session: draw a screen, act on the command it returns, draw
### the next, until Quit. Returns the transcript -- every screen's model
### and events, in order -- which is what the 7.2 gate compares between
### the two renderers.
func ShellSession()
	cLog = ""
	cStatus = "ready"
	while 1
		ui = Window("RingPad", [
			Label("File"),
			Choice(:file, $files),
			Label("Editor  (placeholder: Text is the contract's hard widget)"),
			Entry(:line),
			Menu(:cmd, [ "Open", "Save", "Quit" ]),
			Status(cStatus) ])
		m = Run(ui)
		cLog += RppSerialise(m, $RppEvents) + "#"
		cCmd = m[:cmd]
		if cCmd = "Open"
			cStatus = "opened " + m[:file]
		but cCmd = "Save"
			cStatus = "saved " + m[:file] + " (" + len(m[:line]) + " chars)"
		but cCmd = "Quit"
			exit
		ok
	end
	return cLog
