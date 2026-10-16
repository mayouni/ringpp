// A REFCOUNT UNDERFLOW, reduced -- FIXED 2026-09-04, kept as the guard.
//
// The cause was in the CLASSIFIER, not here: an identifier it could not
// resolve -- a $global, or a local not yet defined -- was classified as
// an INT, and `.int` is the one class that switches refcounting off. So
// `Choice(:file, $files)` typed its parameter int, its register fell
// outside the boxed mask, `move` copied a live vector without retaining
// it, and a string three frees later went to rc -1.
//
// `Menu`, the same signature one line below Choice, was correct only
// because it happens to write `aItems[1]`, which proves the parameter is
// a list. That is how narrowly this missed being found a week earlier.
//
// Below is the original note, kept because the ruled-out list is what
// made the search finite.
//
// ORIGINAL. Measured 2026-09-04.
//
// RingPad's shell loop, driven by the SCRIPTED browser renderer -- no
// socket, no console -- with RppWebHtml() called once per screen. On the
// second screen the VM panics:
//
//     thread panic: integer overflow
//     main.zig:815 in release   <- o.rc -= 1 on a STRING whose rc is 0
//     main.zig:1041 in freeVec  <- releasing a vector's elements
//
// A string is released more often than it was retained, and the frees
// recurse through nested vectors until one of them goes negative.
//
// WHAT IT IS NOT, each ruled out on its own and each clean:
//   * the socket -- this file never opens one
//   * web_wait's nested list -- copying the form into plain Ring strings
//     first changes nothing
//   * RppWebEsc, RppWebText, RppWebOptions -- 200 rounds each, clean
//   * RppWebHtml on a rebuilt tree -- 200 rounds, clean
//   * the same shell loop WITHOUT RppWebHtml -- clean, and it is what
//     examples/12 gates on every run
//
// It needs the shell loop AND the HTML frame together, which is why the
// terminal renderers never show it: they draw with `see` and build no
// string tree. Not yet reduced further; this file is the smallest case
// that fails, and it fails in seconds.
//
//   rnxc exec bench/webloop.ring

# RingPad's shell in a BROWSER, live. Ring++ only.
#
#   Run it:   rnxc exec examples/12-the-ringpad-shell/web_live.ring
#   Open it:  http://127.0.0.1:8773
#
# The SAME loop as the terminal shell: choose a command, the program acts,
# the next screen is drawn. Each menu item is a button; choosing one ends
# the screen, and the browser is sent back for the next one by a redirect.
# The listener stays open across screens -- RppWebBye() closes it at Quit,
# with a last page so the browser is not answered by a dead port.
#
# Open a file, type in the editor, Save, edit again, Undo, then Quit.

load "D:/GitHub/ringpp/rpp/tui.ring"

$files = [ "notes.ring", "main.ring", "test.ring" ]
$store = []
$scr = 0
$html = ""

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

		$scr++
		if $scr = 1
			$RppWeb = [ [ :set, :file, "main.ring" ], [ :set, :doc, [ "" ] ], [ :pick, :cmd, "Open" ] ]
		but $scr = 2
			$RppWeb = [ [ :set, :file, "main.ring" ], [ :set, :doc, [ "one", "two" ] ], [ :pick, :cmd, "Save" ] ]
		but $scr = 3
			$RppWeb = [ [ :set, :file, "main.ring" ], [ :set, :doc, [ "one", "two" ] ], [ :pick, :cmd, "Undo" ] ]
		else
			$RppWeb = [ [ :set, :file, "main.ring" ], [ :set, :doc, [ "" ] ], [ :pick, :cmd, "Quit" ] ]
		ok
		$html = RppWebHtml(ui, RppTuiModel(RppFlat(ui[:children])))
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
