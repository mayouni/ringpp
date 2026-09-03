### Ring++ — the widget tree, and its first renderer: the terminal.
###
### THE CONTRACT this implements is docs/WIDGET-TREE-CONTRACT.md. A tree is
### a plain hash list; a renderer draws it and writes the MODEL, and the
### model -- another plain hash list -- is the only state that matters. A
### program never touches a widget object; it reads its own map.
###
### THIS RENDERER IS LINE-DRIVEN, on purpose. Measured on Ring 1.27 on
### 2026-09-02: `give` reads a line from piped stdin, ESC sequences reach
### stdout unmangled, and getchar() under a pipe returns one character --
### but whether a live Windows console delivers a raw key without Enter is
### gate 3 of the contract and is NOT verified. So this asks for a line per
### field and draws with ANSI, which runs on Ring 1.27 today with no native
### code at all; the raw-key renderer arrives with its own probe and number.
###
### SCRIPTED INPUT IS THE GATE, not an afterthought. If $RppKeys holds
### lines, Run() consumes those instead of the keyboard, draws plainly (no
### escape bytes in a transcript), and appends every event to $RppEvents.
### Same tree, same lines, same model: that is how a second renderer will
### be judged against this one, and how the example runs unattended.
###
### NAMING. The contract writes Input(:name). `input` is a Ring builtin,
### and a user function REPLACES a builtin of the same name process-wide
### (measured: with func Max defined, max(3, 9) raises R20), so a library
### must not take it. Entry is the word a learner from Python knows.
###
### READS NEVER GUESS. On Ring 1.27 a keyed read of a missing key INSERTS
### it (FINDINGS F-49), so the model is populated with every Entry's name
### before anything reads it, and no read here can create an entry.

$RppKeys   = []          # scripted lines; empty means "use the keyboard"
$RppEvents = []          # every [kind, name, value] the renderer produced
$RppEsc    = char(27)    # ANSI escape, cached: char() is a C call (F-4)
$RppPlain  = 0           # 1 while scripted: no escape bytes in the output
$RppTextRows = 6         # the terminal renderer's Text viewport (contract 6.2)
$RppBsN    = char(92) + "n"   # a literal backslash-n, for one-line transcripts (6.1)

### ---------------------------------------------------------- the tree

func Window(cTitle, aChildren)
	return [ :kind = "window", :title = cTitle, :children = aChildren ]

func Label(cText)
	return [ :kind = "label", :text = cText ]

func Entry(cName)
	return [ :kind = "entry", :name = cName ]

func Button(cText, cEvent)
	return [ :kind = "button", :text = cText, :event = cEvent ]

### Checkbox: the model holds 1 or 0. (Not Check: three of this repo's own
### tests define a `func Check` assertion helper, and Ring refuses a second
### definition outright -- C22 -- so a library taking that name stops those
### programs from loading at all.) Radio and Choice: the model holds the
### chosen option's TEXT, "" until one is chosen; both keep their options
### under :options so one drawing and one selecting path serve both. The
### contract writes List for the second; `list(n)` is a Ring builtin and a
### user function replaces a builtin process-wide, so -- like Entry for
### Input -- the library cannot take the name. Choice it is.
func Checkbox(cName, cLabel)
	return [ :kind = "check", :name = cName, :label = cLabel ]

func Radio(cName, aOptions)
	return [ :kind = "radio", :name = cName, :options = aOptions ]

func Choice(cName, aItems)
	return [ :kind = "choice", :name = cName, :options = aItems ]

### Menu: a list of commands. The model holds the chosen item's TEXT, and
### choosing one ENDS the screen -- :change, :click and :submit, in that
### order -- so the program can act on it and draw the next screen. That is
### what makes a shell possible without the callback form of Run (§4).
func Menu(cName, aItems)
	return [ :kind = "menu", :name = cName, :options = aItems ]

### Status: a line at the foot of the window, showing text the program
### passes in. Not focusable and not in the model -- it is presentation, and
### the program rebuilds the tree with new text when it has news.
###
### IT MUST NOT LOOK LIKE A CONTROL. Drawn as "[ ready ]" it was read as a
### button somebody should be able to focus (Mansour, on a live console),
### because brackets in this renderer already mean "a value lives here" --
### [Hello] is an entry, [ ] and [*] a checkbox and a choice -- and
### parentheses mean a button. A status line borrows none of them and says
### what it is.
func Status(cText)
	return [ :kind = "status", :text = cText ]

### Text: the multi-line editor, built to contract 6.1-6.5. The model
### holds [ aLines, nRow, nCol ] -- lines as a list of strings, the cursor
### as a 1-based row and the column BEFORE which it sits. Inside a Text,
### Enter is a line break and Tab leaves (6.4). No undo here (6.3): history
### is the program's, because it is history OF THE MODEL.
func Text(cName)
	return [ :kind = "text", :name = cName ]

### Table: columns and rows, the model holding the SELECTED ROW number
### (0 = none). A digit selects a row in both renderers, so a line "2" and
### a key "2" leave the same model. Minimal by design: Softanza's Show()
### draws the rich table (rounded box, aligned numbers), reached through a
### Softanza-backed renderer -- a different renderer on the same tree, not
### this dependency-free foundation, which cannot load Softanza.
func Table(cName, aColumns, aRows)
	return [ :kind = "table", :name = cName, :columns = aColumns, :rows = aRows ]

### ---------------------------------------------------------- the renderer

### Run(tree) -> the model, when the submit button is pressed or the
### children are exhausted. No callback in this first cut: Ring 1.27's
### anonymous functions see only globals (measured, charter 4e), so a
### handler that needs the model would need the model to be global. The
### program reads what Run() returns, and $RppEvents for the history.
func Run(oTree)
	$RppEvents = []
	$RppPlain  = 0
	if len($RppKeys) > 0
		$RppPlain = 1
	ok

	aKids = oTree[:children]
	nKids = len(aKids)

	# every widget that holds a value exists in the model BEFORE any read (F-49)
	aModel = RppTuiModel(aKids)

	RppTuiDraw(oTree, aModel)
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		if cKind = "entry"
			cName = oKid[:name]
			cLine = RppTuiRead(cName + "> ")
			aModel[cName] = cLine
			$RppEvents + [ :change, cName, cLine ]
			RppTuiDraw(oTree, aModel)
		but cKind = "check"
			cName = oKid[:name]
			cLine = RppTuiRead(cName + " [y/n]> ")
			aModel[cName] = RppTuiYes(cLine)
			$RppEvents + [ :change, cName, aModel[cName] ]
			RppTuiDraw(oTree, aModel)
		but cKind = "radio" or cKind = "choice"
			cName = oKid[:name]
			aOpts = oKid[:options]
			cLine = RppTuiRead(cName + " [1-" + len(aOpts) + "]> ")
			RppTuiPick(aModel, cName, aOpts, cLine)
			$RppEvents + [ :change, cName, aModel[cName] ]
			RppTuiDraw(oTree, aModel)
		but cKind = "table"
			cName = oKid[:name]
			nRows = len(oKid[:rows])
			cLine = RppTuiRead(cName + " row [1-" + nRows + "]> ")
			RppTuiPickRow(aModel, cName, nRows, cLine)
			$RppEvents + [ :change, cName, aModel[cName] ]
			RppTuiDraw(oTree, aModel)
		but cKind = "text"
			# contract 6.4: the line-driven way to edit a buffer. Each line
			# is one prompt; a blank line ends the field; the cursor ends
			# after the last character of the last line.
			cName = oKid[:name]
			aLines = []
			nLine = 1
			while 1
				cLine = RppTuiRead(cName + " [line " + nLine + "]> ")
				if cLine = ""
					exit
				ok
				aLines + cLine
				nLine++
			end
			if len(aLines) = 0
				aLines + ""
			ok
			nR = len(aLines)
			nC = len(aLines[nR]) + 1
			aDoc = [ aLines, nR, nC ]
			aModel[cName] = aDoc
			$RppEvents + [ :change, cName, aDoc ]
			RppTuiDraw(oTree, aModel)
		but cKind = "menu"
			cName = oKid[:name]
			aOpts = oKid[:options]
			cLine = RppTuiRead(cName + " [1-" + len(aOpts) + "]> ")
			RppTuiPick(aModel, cName, aOpts, cLine)
			$RppEvents + [ :change, cName, aModel[cName] ]
			$RppEvents + [ :click, aModel[cName], "" ]
			$RppEvents + [ :submit, "", "" ]
			return aModel
		but cKind = "button"
			cLine = RppTuiRead("[" + oKid[:text] + "] Enter> ")
			$RppEvents + [ :click, oKid[:text], "" ]
			if oKid[:event] = :submit
				$RppEvents + [ :submit, "", "" ]
				return aModel
			ok
		ok
	next
	$RppEvents + [ :close, "", "" ]
	return aModel

### The model a tree starts with: "" for text and choices, 0 for a check.
func RppTuiModel(aKids)
	aModel = []
	nKids = len(aKids)
	for i = 1 to nKids
		cKind = aKids[i][:kind]
		if cKind = "entry" or cKind = "radio" or cKind = "choice"
			aModel + [ aKids[i][:name], "" ]
		but cKind = "check"
			aModel + [ aKids[i][:name], 0 ]
		but cKind = "table"
			aModel + [ aKids[i][:name], 1 ]
		but cKind = "menu"
			aModel + [ aKids[i][:name], aKids[i][:options][1] ]
		but cKind = "text"
			aDoc = [ [ "" ], 1, 1 ]
			aModel + [ aKids[i][:name], aDoc ]
		ok
	next
	return aModel

### y / Y / 1 mean yes; anything else means no. Same rule for a typed line
### and for a single key, so the two renderers agree.
func RppTuiYes(c)
	if c = "y" or c = "Y" or c = "1"
		return 1
	ok
	return 0

### A digit selects an option, by position; out of range leaves the model
### alone. Same rule for a line and for a key.
func RppTuiPick(aModel, cName, aOpts, c)
	if len(c) = 0
		return
	ok
	nSel = number(c)
	if nSel >= 1 and nSel <= len(aOpts)
		aModel[cName] = aOpts[nSel]
	ok

### The list-like widgets: a table, a radio group, a choice list, a menu.
### They differ in what the model holds -- a row NUMBER for a table, the
### item's TEXT for the rest -- so these three say "how long", "which one"
### and "choose that one" without the callers caring which kind it is.
func RppTuiIsList(cKind)
	if cKind = "table" or cKind = "radio" or cKind = "choice" or cKind = "menu"
		return 1
	ok
	return 0

func RppTuiListLen(oKid)
	if oKid[:kind] = "table"
		return len(oKid[:rows])
	ok
	return len(oKid[:options])

func RppTuiSelIndex(oKid, aModel)
	if oKid[:kind] = "table"
		return aModel[oKid[:name]]
	ok
	aOpts = oKid[:options]
	cNow = aModel[oKid[:name]]
	nOpts = len(aOpts)
	for i = 1 to nOpts
		if aOpts[i] = cNow
			return i
		ok
	next
	return 0

func RppTuiSetSel(oKid, aModel, nIdx)
	if oKid[:kind] = "table"
		aModel[oKid[:name]] = nIdx
	else
		aModel[oKid[:name]] = oKid[:options][nIdx]
	ok

### A digit selects a ROW by number; the model holds the number, not the
### row. Out of range leaves it. Same rule for a line and a key.
func RppTuiPickRow(aModel, cName, nRows, c)
	if len(c) = 0
		return
	ok
	nSel = number(c)
	if nSel >= 1 and nSel <= nRows
		aModel[cName] = nSel
	ok

### The table's lines: an ASCII frame, columns sized to their widest cell,
### the selected row marked with a leading ">". cIndent prefixes every
### line so a focused table can shift under its mark. Each line ends the
### way the frames do: ESC[K then nl when drawing live, nl alone when
### scripted.
func RppTuiTableShow(oKid, aModel, bFocus)
	aCols = oKid[:columns]
	aRows = oKid[:rows]
	nCols = len(aCols)
	nRows = len(aRows)

	aW = []
	for j = 1 to nCols
		nWid = len("" + aCols[j])
		for r = 1 to nRows
			nc = len("" + aRows[r][j])
			if nc > nWid
				nWid = nc
			ok
		next
		aW + nWid
	next

	cSep = "+"
	for j = 1 to nCols
		cSep += copy("-", aW[j] + 2) + "+"
	next

	RppTuiTableLine("    " + cSep)
	cH = "|"
	for j = 1 to nCols
		cH += " " + RppTuiPad("" + aCols[j], aW[j]) + " |"
	next
	RppTuiTableLine("    " + cH)
	RppTuiTableLine("    " + cSep)

	# the selected row: "> " when this table has the focus (its arrows are
	# live), "* " when it does not but the selection still stands.
	cSelMark = "* "
	if bFocus = 1
		cSelMark = "> "
	ok
	nSel = aModel[oKid[:name]]
	for r = 1 to nRows
		cRowMark = "  "
		if r = nSel
			cRowMark = cSelMark
		ok
		cRow = "|"
		for j = 1 to nCols
			cRow += " " + RppTuiPad("" + aRows[r][j], aW[j]) + " |"
		next
		RppTuiTableLine("  " + cRowMark + cRow)
	next
	RppTuiTableLine("    " + cSep)

func RppTuiTableLine(cStr)
	see cStr
	if $RppPlain = 0
		see $RppEsc + "[K"
	ok
	see nl

### cStr padded with spaces to width nW. Never truncates: nW is the
### column's widest cell, so cStr already fits.
func RppTuiPad(cStr, nW)
	nGap = nW - len(cStr)
	if nGap > 0
		return cStr + copy(" ", nGap)
	ok
	return cStr

### One line for a radio or choice: every option numbered, the chosen one
### marked -- (o) for a radio, [*] for a choice -- so the number to type
### is on the screen.
func RppTuiOptsLine(oKid, aModel)
	aOpts = oKid[:options]
	cNow = aModel[oKid[:name]]
	cOn = "(o) "
	cOff = "( ) "
	if oKid[:kind] = "choice"
		cOn = "[*] "
		cOff = "[ ] "
	but oKid[:kind] = "menu"
		cOn = "> "
		cOff = "  "
	ok
	cLine = oKid[:name] + ": "
	nOpts = len(aOpts)
	for j = 1 to nOpts
		if aOpts[j] = cNow
			cLine += cOn
		else
			cLine += cOff
		ok
		cLine += "" + j + "." + aOpts[j] + "  "
	next
	return cLine

### One line of input: the next scripted line if there is one, echoed so
### a transcript reads like a session; otherwise the keyboard.
func RppTuiRead(cPrompt)
	if len($RppKeys) > 0
		cLine = $RppKeys[1]
		del($RppKeys, 1)
		see cPrompt + cLine + nl
		return cLine
	ok
	see cPrompt
	give cLine
	return cLine

### Paint the whole window. Flow layout, top to bottom; no geometry, no
### pixels, and none will ever be added here (contract, gate 4).
func RppTuiDraw(oTree, aModel)
	cTitle = oTree[:title]
	if $RppPlain = 0
		see $RppEsc + "[2J" + $RppEsc + "[H"
		see $RppEsc + "[1m" + cTitle + $RppEsc + "[0m" + nl
	else
		see cTitle + nl
	ok
	see copy("-", len(cTitle)) + nl
	aKids = oTree[:children]
	nKids = len(aKids)
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		if cKind = "label"
			see oKid[:text] + nl
		but cKind = "entry"
			see "  [" + aModel[oKid[:name]] + "]" + nl
		but cKind = "check"
			see "  " + RppTuiBox(aModel[oKid[:name]]) + " " + oKid[:label] + nl
		but cKind = "radio" or cKind = "choice"
			see "  " + RppTuiOptsLine(oKid, aModel) + nl
		but cKind = "table"
			RppTuiTableShow(oKid, aModel, 0)
		but cKind = "menu"
			see "  " + RppTuiOptsLine(oKid, aModel) + nl
		but cKind = "text"
			RppTuiTextShow(oKid, aModel, 0)
		but cKind = "status"
			see "  status: " + oKid[:text] + nl
		but cKind = "button"
			see "  ( " + oKid[:text] + " )" + nl
		ok
	next
	see nl

func RppTuiBox(nChecked)
	if nChecked = 1
		return "[x]"
	ok
	return "[ ]"

### ---------------------------------------------------------- the 7.2 harness

### One string for a model and an event log, built by hand so a plain `=`
### compares BYTES. Contract 7.2: two renderers fed the same keys must
### leave byte-identical model state -- this is the string that is compared.
func RppSerialise(aModel, aEvents)
	cOut = "model:"
	nM = len(aModel)
	for i = 1 to nM
		cOut += aModel[i][1] + "=" + RppTuiSerVal(aModel[i][2]) + "|"
	next
	cOut += "events:"
	nE = len(aEvents)
	for i = 1 to nE
		cOut += aEvents[i][1] + "," + aEvents[i][2] + "," + RppTuiSerVal(aEvents[i][3]) + "|"
	next
	return cOut

### One value as transcript text. A string or a number is itself; a Text
### value (contract 6.1) is row, col, then the lines joined by a LITERAL
### backslash-n, so a multi-line buffer stays one line and the comparison
### stays a byte comparison. Starts from "" so a number is never the left
### operand of + (number + non-numeric string is R41 on 1.27, measured).
func RppTuiSerVal(v)
	if islist(v)
		cOut = "" + v[2] + "," + v[3] + ","
		aL = v[1]
		# not nL: Ring identifiers are case-insensitive, and nL IS nl -- the
		# newline constant -- which this overwrote with a line count (F-18).
		nLines = len(aL)
		for i = 1 to nLines
			if i > 1
				cOut += $RppBsN
			ok
			cOut += aL[i]
		next
		return cOut
	ok
	return "" + v

### ---------------------------------------------------------- the keystroke renderer

### RunKeys(tree) -> the model. Contract 7.2's SECOND renderer: the same
### tree, driven by KEYS. A character types into the focused field,
### <backspace> deletes, <tab> <down> <up> move the focus, <enter> leaves a
### field or presses a button, <esc> closes. It repaints IN PLACE through
### the four console builtins (tui_init/key/size/done), so it RUNS on Ring++
### only; it is defined here so the library still loads on Ring 1.27 --
### only a call needs the builtins.
###
### EVENTS ARE PER FIELD, NOT PER KEY. :change fires when a field is LEFT,
### with its whole value, so this renderer's event log is byte-identical
### to the line renderer's for the same session -- which is the 7.2 gate.
### Scripted keys come from $RppKeys, one key per entry: "a", "m",
### "<enter>" -- exactly the names tui_key() returns. When they are
### present nothing touches the console and the frame is drawn plainly,
### once at the start and once at the end.
func RunKeys(oTree)
	$RppEvents = []
	$RppPlain = 1
	nLive = 0
	if len($RppKeys) = 0
		nLive = tui_init()
		if nLive = 1
			$RppPlain = 0
			# ONE full clear for the first frame. Homing alone painted the
			# window over whatever was on screen -- the previous command line
			# showed through the separator on the first live run.
			see $RppEsc + "[2J"
		ok
	ok

	aKids = oTree[:children]
	nKids = len(aKids)
	aModel = RppTuiModel(aKids)
	aFocus = []
	for i = 1 to nKids
		if aKids[i][:kind] != "label" and aKids[i][:kind] != "status"
			aFocus + i
		ok
	next
	nFocus = 1
	nF = len(aFocus)

	RppTuiDrawK(oTree, aModel, aFocus, nFocus)
	while 1
		k = RppTuiKey()
		if k = ""
			$RppEvents + [ :close, "", "" ]
			exit
		ok
		oKid = aKids[ aFocus[nFocus] ]
		cKind = oKid[:kind]
		if k = "<esc>"
			$RppEvents + [ :close, "", "" ]
			exit
		but k = "<enter>"
			if cKind = "button"
				$RppEvents + [ :click, oKid[:text], "" ]
				if oKid[:event] = :submit
					$RppEvents + [ :submit, "", "" ]
					exit
				ok
			but cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but cKind = "menu"
				RppTuiLeave(oKid, aModel)
				$RppEvents + [ :click, aModel[oKid[:name]], "" ]
				$RppEvents + [ :submit, "", "" ]
				exit
			else
				RppTuiLeave(oKid, aModel)
				if nFocus < nF
					nFocus++
				ok
			ok
		but k = "<down>"
			if cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but RppTuiIsList(cKind) = 1 and RppTuiSelIndex(oKid, aModel) < RppTuiListLen(oKid)
				RppTuiSetSel(oKid, aModel, RppTuiSelIndex(oKid, aModel) + 1)
			else
				RppTuiLeave(oKid, aModel)
				if nFocus < nF
					nFocus++
				ok
			ok
		but k = "<up>"
			if cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but RppTuiIsList(cKind) = 1 and RppTuiSelIndex(oKid, aModel) > 1
				RppTuiSetSel(oKid, aModel, RppTuiSelIndex(oKid, aModel) - 1)
			else
				RppTuiLeave(oKid, aModel)
				if nFocus > 1
					nFocus--
				ok
			ok
		but k = "<tab>"
			RppTuiLeave(oKid, aModel)
			if nFocus < nF
				nFocus++
			ok
		but k = "<left>" or k = "<right>" or k = "<home>" or k = "<end>" or k = "<delete>"
			if cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			ok
		but k = "<backspace>"
			if cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but cKind = "entry"
				cV = aModel[oKid[:name]]
				if len(cV) > 0
					aModel[oKid[:name]] = left(cV, len(cV) - 1)
				ok
			ok
		but len(k) = 1
			if cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but cKind = "entry"
				aModel[oKid[:name]] = aModel[oKid[:name]] + k
			but cKind = "check"
				if k = " "
					aModel[oKid[:name]] = 1 - aModel[oKid[:name]]
				else
					aModel[oKid[:name]] = RppTuiYes(k)
				ok
			but cKind = "radio" or cKind = "choice"
				RppTuiPick(aModel, oKid[:name], oKid[:options], k)
			but cKind = "table"
				RppTuiPickRow(aModel, oKid[:name], len(oKid[:rows]), k)
			but cKind = "menu"
				RppTuiPick(aModel, oKid[:name], oKid[:options], k)
			ok
		ok
		if $RppPlain = 0
			RppTuiDrawK(oTree, aModel, aFocus, nFocus)
		ok
	end
	if $RppPlain = 1
		RppTuiDrawK(oTree, aModel, aFocus, nFocus)
	ok
	if nLive = 1
		tui_done()
	ok
	return aModel

### Leaving a widget that holds a value: :change fires ONCE, with the whole
### value -- per field, never per key -- which is what keeps this
### renderer's event log byte-identical to the line renderer's.
func RppTuiLeave(oKid, aModel)
	if oKid[:kind] != "button"
		$RppEvents + [ :change, oKid[:name], aModel[oKid[:name]] ]
	ok

### One key applied to a Text (contract 6.4). The model value is copied
### out, edited, and written back -- assignment copies a list on both
### runtimes (measured 2026-09-03), so the write-back is what makes the
### edit land. Line breaks and joins rebuild the line list rather than
### insert into it, so nothing here needs a builtin the other runtime
### might lack.
func RppTuiTextKey(oKid, aModel, k)
	cName = oKid[:name]
	aDoc = aModel[cName]
	aLines = aDoc[1]
	nRow = aDoc[2]
	nCol = aDoc[3]
	nRows = len(aLines)
	cLine = aLines[nRow]
	nLen = len(cLine)
	if k = "<enter>"
		cBefore = left(cLine, nCol - 1)
		cAfter = RppTuiTail(cLine, nCol)
		aNew = []
		for i = 1 to nRows
			if i = nRow
				aNew + cBefore
				aNew + cAfter
			else
				aNew + aLines[i]
			ok
		next
		aLines = aNew
		nRow++
		nCol = 1
	but k = "<backspace>"
		if nCol > 1
			aLines[nRow] = left(cLine, nCol - 2) + RppTuiTail(cLine, nCol)
			nCol--
		but nRow > 1
			cPrev = aLines[nRow - 1]
			aNew = []
			for i = 1 to nRows
				if i = nRow - 1
					aNew + (cPrev + cLine)
				but i != nRow
					aNew + aLines[i]
				ok
			next
			aLines = aNew
			nCol = len(cPrev) + 1
			nRow--
		ok
	but k = "<delete>"
		if nCol <= nLen
			aLines[nRow] = left(cLine, nCol - 1) + RppTuiTail(cLine, nCol + 1)
		but nRow < nRows
			cNext = aLines[nRow + 1]
			aNew = []
			for i = 1 to nRows
				if i = nRow
					aNew + (cLine + cNext)
				but i != nRow + 1
					aNew + aLines[i]
				ok
			next
			aLines = aNew
		ok
	but k = "<left>"
		if nCol > 1
			nCol--
		but nRow > 1
			nRow--
			nCol = len(aLines[nRow]) + 1
		ok
	but k = "<right>"
		if nCol <= nLen
			nCol++
		but nRow < nRows
			nRow++
			nCol = 1
		ok
	but k = "<up>"
		if nRow > 1
			nRow--
			nCol = RppTuiClampCol(aLines[nRow], nCol)
		ok
	but k = "<down>"
		if nRow < nRows
			nRow++
			nCol = RppTuiClampCol(aLines[nRow], nCol)
		ok
	but k = "<home>"
		nCol = 1
	but k = "<end>"
		nCol = nLen + 1
	but len(k) = 1
		aLines[nRow] = left(cLine, nCol - 1) + k + RppTuiTail(cLine, nCol)
		nCol++
	ok
	aDoc[1] = aLines
	aDoc[2] = nRow
	aDoc[3] = nCol
	aModel[cName] = aDoc

### The characters from position n to the end; "" past the end. substr
### past the end is already "" on both runtimes (measured), the guard is
### for the reader.
func RppTuiTail(cStr, n)
	if n > len(cStr)
		return ""
	ok
	return substr(cStr, n)

### A column carried onto a shorter line lands after its last character.
func RppTuiClampCol(cStr, nCol)
	if nCol > len(cStr) + 1
		return len(cStr) + 1
	ok
	return nCol

### Draw a Text: a header with the count and the cursor, then a window of
### lines. THE SCROLLPORT IS COMPUTED HERE AND STORED NOWHERE (contract
### 6.2): $RppTextRows lines that follow the cursor. The cursor is drawn
### as | before the character it sits before.
func RppTuiTextShow(oKid, aModel, bFocus)
	aDoc = aModel[oKid[:name]]
	aLines = aDoc[1]
	nRow = aDoc[2]
	nCol = aDoc[3]
	nRows = len(aLines)
	cMark = "  "
	if bFocus = 1
		cMark = "> "
	ok
	RppTuiTableLine(cMark + oKid[:name] + ":  " + nRows + " line(s), cursor " + nRow + ":" + nCol)
	nTop = 1
	if nRow > $RppTextRows
		nTop = nRow - $RppTextRows + 1
	ok
	nBottom = nTop + $RppTextRows - 1
	if nBottom > nRows
		nBottom = nRows
	ok
	for r = nTop to nBottom
		cLine = aLines[r]
		if r = nRow
			cLine = left(cLine, nCol - 1) + "|" + RppTuiTail(cLine, nCol)
		ok
		RppTuiTableLine("    " + r + ": " + cLine)
	next

### One key: the next scripted one if there is one, else the console's.
func RppTuiKey()
	if len($RppKeys) > 0
		k = $RppKeys[1]
		del($RppKeys, 1)
		return k
	ok
	return tui_key()

### The frame with a focus mark. In-place repaint: home, then each line
### cleared to its end, then everything below cleared -- no full clear,
### so nothing flickers. Still no geometry and no pixels (contract, 7.4).
func RppTuiDrawK(oTree, aModel, aFocus, nFocus)
	cTitle = oTree[:title]
	if $RppPlain = 0
		see $RppEsc + "[H"
		see $RppEsc + "[1m" + cTitle + $RppEsc + "[0m" + $RppEsc + "[K" + nl
	else
		see cTitle + nl
	ok
	see copy("-", len(cTitle))
	if $RppPlain = 0
		see $RppEsc + "[K"
	ok
	see nl
	aKids = oTree[:children]
	nKids = len(aKids)
	nHere = aFocus[nFocus]
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		cMark = "  "
		if i = nHere
			cMark = "> "
		ok
		if cKind = "label"
			see cMark + oKid[:text]
		but cKind = "entry"
			see cMark + "[" + aModel[oKid[:name]] + "]"
		but cKind = "check"
			see cMark + RppTuiBox(aModel[oKid[:name]]) + " " + oKid[:label]
		but cKind = "radio" or cKind = "choice"
			see cMark + RppTuiOptsLine(oKid, aModel)
		but cKind = "table"
			bF = 0
			if i = nHere
				bF = 1
			ok
			RppTuiTableShow(oKid, aModel, bF)
			loop
		but cKind = "menu"
			see cMark + RppTuiOptsLine(oKid, aModel)
		but cKind = "text"
			bF = 0
			if i = nHere
				bF = 1
			ok
			RppTuiTextShow(oKid, aModel, bF)
			loop
		but cKind = "status"
			see cMark + "status: " + oKid[:text]
		but cKind = "button"
			see cMark + "( " + oKid[:text] + " )"
		ok
		if $RppPlain = 0
			see $RppEsc + "[K"
		ok
		see nl
	next
	if $RppPlain = 0
		see $RppEsc + "[J"
	ok
	see nl
