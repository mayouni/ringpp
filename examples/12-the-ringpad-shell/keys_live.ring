# RingPad's shell, LIVE: your keyboard, your console, Ring++ only.
#
#   Run it:  rnxc exec examples/12-the-ringpad-shell/keys_live.ring
#
# Up and Down move within any list -- the file list and the menu alike.
# Enter leaves a field, or ACTIVATES a menu item: the screen ends, the
# program acts, and the next screen is drawn with a new status line.
# Choose Quit to leave; Esc closes at any point.
#
# The editor is a one-line Entry standing where `Text` will go. That is
# the whole point of building the shell first: it names what the hard
# widget has to do, instead of guessing.

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
$log = ShellSession()
? "session over"

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
		m = RunKeys(ui)
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
