# Ring++ example 12, the SECOND renderer: RingPad's shell driven by KEYS.
#
# Runs on Ring++ only. The other half of contract gate 7.2 for the shell:
# the same two screens -- save main.ring, then quit -- typed as keys
# instead of lines, and the transcript of both screens must be
# byte-identical to example.ring's.
#
#   screen 1:  2 Enter          pick main.ring from the file list
#              h e l l o Enter  type into the editor placeholder
#              Down Enter       menu: Open -> Save, activate
#   screen 2:  1 Enter          pick notes.ring
#              Enter            leave the editor empty
#              Down Down Enter  menu: Open -> Save -> Quit, activate
#
# Live: empty $RppKeys and run it with rnxc exec. Arrows move within any
# list -- the file list and the menu alike -- Enter leaves a field or
# activates a menu item, Esc closes.
#
#   Run it:  rnxc exec examples/12-the-ringpad-shell/keys.ring

load "../../rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]

$RppKeys = [ "2", "<enter>", "h", "e", "l", "l", "o", "<enter>", "<down>", "<enter>",
             "1", "<enter>", "<enter>", "<down>", "<down>", "<enter>" ]
$log = ShellSession()
? ""
? "serial: " + $log
? "SHELL DONE"

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
