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
$RppFocus  = ""          # the widget to focus first, by name; "" = the first one
$RppOn     = 0           # the installed handler, when $RppHasOn = 1
$RppHasOn  = 0           # a function value is not comparable to "", so a flag
$RppClose  = 0           # the handler asked to close the window
$RppModel  = []          # the live model, so a handler can read it (globals only)
$RppLiveModel = []       # born HERE: on Ring 1.27 a $name first assigned inside
                         # a function is a LOCAL of it (Rule A discipline)
$RppSaid   = ""          # what RppSay() put in the status line, this run
$RppSaidSet = 0
$RppWeb    = []          # scripted BROWSER events; empty means "use the socket"
$RppServing = 0          # the socket banner is printed once, not per screen
$RppScreenRow = 0        # the keystroke frame counts the lines it draws ...
$RppCursorAt = []        # ... to put the console's cursor at [row, col], live only

### ---------------------------------------------------------- the tree

func Window(cTitle, aChildren)
	return [ :kind = "window", :title = cTitle, :children = aChildren ]

func Label(cText)
	return [ :kind = "label", :text = cText ]

func Entry(cName)
	return [ :kind = "entry", :name = cName, :value = "" ]

### With(node, value): the node with its starting value -- what a previous
### screen left, so a choice or a field carries across screens. Every value
### widget sets :value in its constructor, so this only ever overwrites.
func With(oNode, v)
	oNode[:value] = v
	return oNode

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
	return [ :kind = "check", :name = cName, :label = cLabel, :value = 0 ]

func Radio(cName, aOptions)
	return [ :kind = "radio", :name = cName, :options = aOptions, :value = "" ]

func Choice(cName, aItems)
	return [ :kind = "choice", :name = cName, :options = aItems, :value = "" ]

### Menu: a list of commands. The model holds the chosen item's TEXT, and
### choosing one ENDS the screen -- :change, :click and :submit, in that
### order -- so the program can act on it and draw the next screen. That is
### what makes a shell possible without the callback form of Run (§4).
func Menu(cName, aItems)
	return [ :kind = "menu", :name = cName, :options = aItems, :value = aItems[1] ]

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
	aDoc = [ [ "" ], 1, 1 ]
	return [ :kind = "text", :name = cName, :value = aDoc ]

### TextWith: a Text that opens with content -- the value a previous
### screen left, a file's lines as [ aLines, 1, 1 ], or a value restored by
### an Undo the PROGRAM keeps (contract 6.3). Both constructors set :value,
### so the model never has to read a key that might be missing (F-49).
func TextWith(cName, aDoc)
	return [ :kind = "text", :name = cName, :value = aDoc ]

### Table: columns and rows, the model holding the SELECTED ROW number
### (0 = none). A digit selects a row in both renderers, so a line "2" and
### a key "2" leave the same model. Minimal by design: Softanza's Show()
### draws the rich table (rounded box, aligned numbers), reached through a
### Softanza-backed renderer -- a different renderer on the same tree, not
### this dependency-free foundation, which cannot load Softanza.
func Table(cName, aColumns, aRows)
	return [ :kind = "table", :name = cName, :columns = aColumns, :rows = aRows, :value = 1 ]

### Row: children side by side instead of stacked. A container, like
### Window -- it holds no value, takes no focus and appears in no model.
### It promises NOTHING about width (§7.4): how much room each child gets
### is the renderer's business, as the scrollport is (§6.2).
###
### A Row is meant for the single-line widgets. A Text or a Table inside
### one is drawn on its own lines, because a multi-line widget cannot sit
### beside anything and pretending otherwise would be geometry.
func Row(aChildren)
	return [ :kind = "row", :children = aChildren ]

### The widgets in order, with Rows opened out. The model, the focus ring
### and the event loops all use THIS; only the drawing walks the nesting.
### That is what makes a Row invisible to the transcript, and example 15
### is the gate that says so.
func RppFlat(aKids)
	aOut = []
	nK = len(aKids)
	for i = 1 to nK
		oKid = aKids[i]
		if oKid[:kind] = "row"
			aInner = RppFlat(oKid[:children])
			nI = len(aInner)
			for j = 1 to nI
				aOut + aInner[j]
			next
		else
			aOut + oKid
		ok
	next
	return aOut

### A widget's identity for the frame. Focus was an INDEX into the
### children, which a Row breaks: the flat order and the drawn order are
### no longer the same list. A key survives the nesting.
func RppKeyOf(oKid)
	cKind = oKid[:kind]
	if cKind = "button"
		return "b:" + oKid[:text]
	but cKind = "label"
		return "l:" + oKid[:text]
	but cKind = "status"
		return "s:"
	but cKind = "row"
		return "r:"
	ok
	return "w:" + oKid[:name]

### ---------------------------------------------------------- the renderer

### Run(tree) -> the model, when the submit button is pressed or the
### children are exhausted. The program reads what Run() returns, and
### $RppEvents for the history. RunOn(tree, handler), below, is the
### callback form: a handler that runs in place while the window is
### still open, for when the program needs to react before the screen
### ends rather than after.
func Run(oTree)
	$RppEvents = []
	RppResetOn()
	$RppPlain  = 0
	if len($RppKeys) > 0
		$RppPlain = 1
	ok

	aKids = RppFlat(oTree[:children])
	nKids = len(aKids)

	# every widget that holds a value exists in the model BEFORE any read (F-49)
	aModel = RppTuiModel(aKids)
	$RppLiveModel = aModel

	RppTuiDraw(oTree, aModel)
	for i = 1 to nKids
		if $RppClose = 1
			exit
		ok
		oKid = aKids[i]
		cKind = oKid[:kind]
		$RppLiveModel = aModel
		if cKind = "entry"
			cName = oKid[:name]
			cLine = RppTuiRead(cName + "> ")
			aModel[cName] = cLine
			RppFire(:change, cName, cLine)
			RppTuiDraw(oTree, aModel)
		but cKind = "check"
			cName = oKid[:name]
			cLine = RppTuiRead(cName + " [y/n]> ")
			aModel[cName] = RppTuiYes(cLine)
			RppFire(:change, cName, aModel[cName])
			RppTuiDraw(oTree, aModel)
		but cKind = "radio" or cKind = "choice"
			cName = oKid[:name]
			aOpts = oKid[:options]
			cLine = RppTuiRead(cName + " [1-" + len(aOpts) + "]> ")
			RppTuiPick(aModel, cName, aOpts, cLine)
			RppFire(:change, cName, aModel[cName])
			RppTuiDraw(oTree, aModel)
		but cKind = "table"
			cName = oKid[:name]
			nRows = len(oKid[:rows])
			cLine = RppTuiRead(cName + " row [1-" + nRows + "]> ")
			RppTuiPickRow(aModel, cName, nRows, cLine)
			RppFire(:change, cName, aModel[cName])
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
				# a blank FIRST line keeps the field as it is -- the only way
				# a line-driven interface can say "leave it", and the same
				# result as Tab under the keystroke renderer. On an empty
				# editor that is still [""] at 1:1.
				aDoc = aModel[cName]
			else
				nR = len(aLines)
				nC = len(aLines[nR]) + 1
				aDoc = [ aLines, nR, nC ]
			ok
			aModel[cName] = aDoc
			RppFire(:change, cName, aDoc)
			RppTuiDraw(oTree, aModel)
		but cKind = "menu"
			cName = oKid[:name]
			aOpts = oKid[:options]
			cLine = RppTuiRead(cName + " [1-" + len(aOpts) + "]> ")
			RppTuiPick(aModel, cName, aOpts, cLine)
			RppFire(:change, cName, aModel[cName])
			RppFire(:click, aModel[cName], "")
			if $RppClose = 1
				RppFire(:close, "", "")
				return aModel
			ok
			RppFire(:submit, "", "")
			return aModel
		but cKind = "button"
			cLine = RppTuiRead("[" + oKid[:text] + "] Enter> ")
			RppFire(:click, oKid[:text], "")
			if $RppClose = 1
				RppFire(:close, "", "")
				return aModel
			ok
			if oKid[:event] = :submit
				RppFire(:submit, "", "")
				return aModel
			ok
		ok
	next
	RppFire(:close, "", "")
	return aModel

### Per-run handler state. The transcript is reset by the renderers; this
### is everything else a handler touches.
func RppResetOn()
	$RppClose = 0
	$RppSaid = ""
	$RppSaidSet = 0
	$RppModel = []
	$RppLiveModel = []

### The model a tree starts with: "" for text and choices, 0 for a check.
func RppTuiModel(aKids)
	aModel = []
	nKids = len(aKids)
	for i = 1 to nKids
		cKind = aKids[i][:kind]
		if cKind != "label" and cKind != "button" and cKind != "status"
			aModel + [ aKids[i][:name], aKids[i][:value] ]
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
	$RppScreenRow++
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

### EVERY event passes through here: it is appended to the transcript and,
### if a handler is installed, that handler is called with it. The handler
### may return :close to close the window. Its arguments are the event,
### spread -- kind, name, value -- so the same handler reads on both
### runtimes without indexing a list.
###
### A HANDLER MAY USE GLOBALS AND NOTHING ELSE. Measured on both runtimes:
### an anonymous function sees globals in each, but only Ring++ sees the
### locals of the function that defined it -- Ring 1.27 raises R24. Writing
### to a global is therefore the only way a handler can report anything
### that both runtimes will run.
func RppFire(cKind, cName, vVal)
	$RppEvents + [ cKind, cName, vVal ]
	if $RppHasOn = 1
		$RppModel = $RppLiveModel
		cAns = call $RppOn(cKind, cName, vVal)
		if cAns = :close
			$RppClose = 1
		ok
	ok

### What a handler says: the status line shows this for the rest of the
### run, in place of whatever text the Status widget was built with. It is
### presentation and appears in no transcript, so it cannot move the gate.
func RppSay(cText)
	$RppSaid = cText
	$RppSaidSet = 1

### Run(tree, handler) and RunKeys(tree, handler) under their own names:
### Ring checks parameter counts, so an optional second parameter is not
### available to either runtime.
func RunOn(oTree, fOn)
	RppInstall(fOn, 1)
	aM = Run(oTree)
	RppInstall(0, 0)
	return aM

func RunKeysOn(oTree, fOn)
	RppInstall(fOn, 1)
	aM = RunKeys(oTree)
	RppInstall(0, 0)
	return aM

func RunWebOn(oTree, fOn)
	RppInstall(fOn, 1)
	aM = RunWeb(oTree)
	RppInstall(0, 0)
	return aM

### The caller says whether a handler is installed. NOT sniffed from the
### value: measured 2026-09-03, an anonymous function on Ring 1.27 IS A
### STRING -- type() says STRING, isstring() says 1, and its length is that
### of a generated name -- so no predicate can tell a handler from a piece
### of text. `call` works on it all the same, on both runtimes.
func RppInstall(fOn, nOn)
	$RppOn = fOn
	$RppHasOn = nOn

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
	# the children AS WRITTEN -- a Row is drawn, never flattened away
	aKids = oTree[:children]
	nKids = len(aKids)
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		if cKind = "row"
			see RppTuiRowLine(oKid, aModel, "") + nl
			RppTuiRowRest(oKid, aModel, "")
		but cKind = "table"
			RppTuiTableShow(oKid, aModel, 0)
		but cKind = "text"
			RppTuiTextShow(oKid, aModel, 0)
		but cKind = "label"
			see RppTuiInline(oKid, aModel) + nl
		else
			see "  " + RppTuiInline(oKid, aModel) + nl
		ok
	next
	see nl

### A Row's multi-line children -- a Text or a Table -- cannot sit beside
### anything, so they are drawn after the row's line, on their own.
func RppTuiRowRest(oRow, aModel, cHere)
	aKids = oRow[:children]
	nK = len(aKids)
	for i = 1 to nK
		oKid = aKids[i]
		if RppTuiFlatDraw(oKid[:kind]) = 0
			bF = 0
			if RppKeyOf(oKid) = cHere
				bF = 1
			ok
			if oKid[:kind] = "table"
				RppTuiTableShow(oKid, aModel, bF)
			else
				RppTuiTextShow(oKid, aModel, bF)
			ok
		ok
	next

### What the status line shows: whatever a handler last said this run,
### otherwise the text the widget was built with.
func RppStatusText(oKid)
	if $RppSaidSet = 1
		return $RppSaid
	ok
	return oKid[:text]

### One line of a single-line widget, without its focus mark. Both
### terminal frames draw through this, so a Row can join several of them
### on one line and they read exactly as they do stacked.
func RppTuiInline(oKid, aModel)
	cKind = oKid[:kind]
	if cKind = "label"
		return oKid[:text]
	but cKind = "entry"
		return "[" + aModel[oKid[:name]] + "]"
	but cKind = "check"
		return RppTuiBox(aModel[oKid[:name]]) + " " + oKid[:label]
	but cKind = "radio" or cKind = "choice" or cKind = "menu"
		return RppTuiOptsLine(oKid, aModel)
	but cKind = "status"
		return "status: " + RppStatusText(oKid)
	but cKind = "button"
		return "( " + oKid[:text] + " )"
	ok
	return ""

### A Row as one line: each child's inline text, the focused one marked
### where it sits. cHere is "" in the line renderer, which has no focus.
func RppTuiRowLine(oRow, aModel, cHere)
	aKids = oRow[:children]
	cOut = ""
	nK = len(aKids)
	for i = 1 to nK
		oKid = aKids[i]
		if i > 1
			cOut += "   "
		ok
		if RppKeyOf(oKid) = cHere
			cOut += "> "
		else
			cOut += "  "
		ok
		cOut += RppTuiInline(oKid, aModel)
	next
	return cOut

### Is this a widget a Row can draw on one line?
func RppTuiFlatDraw(cKind)
	if cKind = "text" or cKind = "table"
		return 0
	ok
	return 1

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
### A value's own characters, escaped so the transcript is INJECTIVE.
### Measured 2026-09-04, after Mansour's live editing session put a comma
### in a value and sent me to look at the joins:
###
###     [ [ "x", "1|y=2" ] ]           model:x=1|y=2|events:
###     [ [ "x", "1" ], [ "y", "2" ] ] model:x=1|y=2|events:
###
### -- two different models, the same bytes, which is a FALSE PASS waiting
### for gate 7.2. A value containing the field separator could impersonate
### a field boundary. Now `\` doubles and `|` is written `\|`, so nothing
### in a value can be mistaken for the frame around it.
###
### Names need no escaping: they are the symbols a tree was built with.
### And this runs BEFORE the line join, so a Text whose content holds no
### backslash serialises exactly as it did -- which is why no expected
### transcript in the examples had to change.
### Replacement, not indexing: `s[i]` on a string is a one-character
### STRING on Ring 1.27 and the character CODE on Ring++, so a loop over
### it escaped "amina" to "9710910511097" on one runtime and not the
### other. The gate caught it on the first run. substr's four-argument
### form means the same thing on both.
###
### `\` FIRST, or the backslash the second pass introduces gets doubled by
### it -- the same order, and the same reason, as RppWebEsc's `&`.
func RppEscVal(cStr)
	cOut = substr("" + cStr, char(92), char(92) + char(92))
	cOut = substr(cOut, "|", char(92) + "|")
	return cOut

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
			cOut += RppEscVal(aL[i])
		next
		return cOut
	ok
	return RppEscVal("" + v)

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
	RppResetOn()
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

	aKids = RppFlat(oTree[:children])
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
	if $RppFocus != ""
		for j = 1 to nF
			oF = aKids[ aFocus[j] ]
			if oF[:kind] != "button" and oF[:name] = $RppFocus
				nFocus = j
			ok
		next
	ok

	RppTuiDrawK(oTree, aModel, aFocus, nFocus)
	while 1
		k = RppTuiKey()
		if k = ""
			RppFire(:close, "", "")
			exit
		ok
		oKid = aKids[ aFocus[nFocus] ]
		cKind = oKid[:kind]
		$RppLiveModel = aModel
		if k = "<esc>"
			RppFire(:close, "", "")
			exit
		but k = "<enter>"
			if cKind = "button"
				RppFire(:click, oKid[:text], "")
				if $RppClose = 1
					RppFire(:close, "", "")
					exit
				ok
				if oKid[:event] = :submit
					RppFire(:submit, "", "")
					exit
				ok
			but cKind = "text"
				RppTuiTextKey(oKid, aModel, k)
			but cKind = "menu"
				RppTuiLeave(oKid, aModel)
				RppFire(:click, aModel[oKid[:name]], "")
				if $RppClose = 1
					RppFire(:close, "", "")
					exit
				ok
				RppFire(:submit, "", "")
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
			else
				nFocus = 1
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
		but len(k) = 1 and ascii(k) >= 32
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
		if $RppClose = 1
			# the branches that close on a click fire :close and exit there,
			# so reaching here means some other event closed the window
			RppFire(:close, "", "")
			exit
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
		RppFire(:change, oKid[:name], aModel[oKid[:name]])
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
			if bFocus = 1 and $RppPlain = 0
				# live and focused: no glyph -- the console's own cursor is
				# put here once the frame is drawn
				$RppCursorAt = [ $RppScreenRow + 1, 4 + len("" + r) + 2 + nCol ]
			else
				cLine = left(cLine, nCol - 1) + "|" + RppTuiTail(cLine, nCol)
			ok
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
	$RppScreenRow = 0
	$RppCursorAt = []
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
	$RppScreenRow = 2
	# the children AS WRITTEN; focus is matched by KEY, because with a Row
	# the drawn order and the flat focus ring are no longer the same list
	aFlat = RppFlat(oTree[:children])
	cHere = RppKeyOf(aFlat[ aFocus[nFocus] ])
	aKids = oTree[:children]
	nKids = len(aKids)
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		cMark = "  "
		if RppKeyOf(oKid) = cHere
			cMark = "> "
		ok
		if cKind = "row"
			see RppTuiRowLine(oKid, aModel, cHere)
			if $RppPlain = 0
				see $RppEsc + "[K"
			ok
			see nl
			$RppScreenRow++
			RppTuiRowRest(oKid, aModel, cHere)
			loop
		but cKind = "label"
			see cMark + oKid[:text]
		but cKind = "entry"
			see cMark + "[" + aModel[oKid[:name]] + "]"
			if RppKeyOf(oKid) = cHere and $RppPlain = 0
				$RppCursorAt = [ $RppScreenRow + 1, len(aModel[oKid[:name]]) + 4 ]
			ok
		but cKind = "check"
			see cMark + RppTuiBox(aModel[oKid[:name]]) + " " + oKid[:label]
		but cKind = "radio" or cKind = "choice"
			see cMark + RppTuiOptsLine(oKid, aModel)
		but cKind = "table"
			bF = 0
			if RppKeyOf(oKid) = cHere
				bF = 1
			ok
			RppTuiTableShow(oKid, aModel, bF)
			loop
		but cKind = "menu"
			see cMark + RppTuiOptsLine(oKid, aModel)
		but cKind = "text"
			bF = 0
			if RppKeyOf(oKid) = cHere
				bF = 1
			ok
			RppTuiTextShow(oKid, aModel, bF)
			loop
		but cKind = "status"
			see cMark + "status: " + RppStatusText(oKid)
		but cKind = "button"
			see cMark + "( " + oKid[:text] + " )"
		ok
		if $RppPlain = 0
			see $RppEsc + "[K"
		ok
		see nl
		$RppScreenRow++
	next
	if $RppPlain = 0
		see $RppEsc + "[J"
	ok
	see nl
	# live: the console's own cursor goes where the focused field is edited,
	# not at the foot of the frame (Mansour, on a live console, 2026-09-03)
	if $RppPlain = 0 and len($RppCursorAt) = 2
		see $RppEsc + "[" + $RppCursorAt[1] + ";" + $RppCursorAt[2] + "H"
	ok

### ---------------------------------------------------------- the browser renderer

### RunWeb(tree) -> the model. THE THIRD RENDERER, and the one contract
### 5.1 promises alongside the terminal: same tree, same model, a browser's
### own event vocabulary.
###
### A browser does not send keys or lines. It sends what happened to a
### CONTROL: a field was SET to a value, a button was PRESSED, a menu item
### was PICKED. Those are the three, and they arrive as a list:
###
###     $RppWeb = [ [ :set, :name, "amina" ], [ :press, "OK" ] ]
###
### The transcript it produces is the one the other two produce for the
### same session -- :change per field with its whole value, :click on a
### button, :submit when the screen ends -- which is gate 7.2's whole
### point: three input vocabularies, one model.
###
### THE SOCKET IS NOT HERE YET. This is the model half, and it is gateable
### without a browser exactly as the keystroke renderer was gateable
### without a console. RppWebHtml() below draws the frame the socket will
### serve; nothing here opens a port.
func RunWeb(oTree)
	$RppEvents = []
	RppResetOn()
	$RppPlain = 1

	aKids = RppFlat(oTree[:children])
	nKids = len(aKids)
	aModel = RppTuiModel(aKids)
	$RppLiveModel = aModel

	nEv = len($RppWeb)
	for i = 1 to nEv
		if $RppClose = 1
			exit
		ok
		aEv = $RppWeb[i]
		cWhat = aEv[1]
		$RppLiveModel = aModel

		if cWhat = :set
			cName = aEv[2]
			vVal = aEv[3]
			oKid = RppWebFind(aKids, cName)
			aModel[cName] = RppWebValue(oKid, vVal)
			RppFire(:change, cName, aModel[cName])

		but cWhat = :press
			cText = aEv[2]
			oKid = RppWebButton(aKids, cText)
			RppFire(:click, cText, "")
			if $RppClose = 1
				RppFire(:close, "", "")
				return aModel
			ok
			if len(oKid) > 0 and oKid[:event] = :submit
				RppFire(:submit, "", "")
				return aModel
			ok

		but cWhat = :pick
			# a menu item: the browser reports the item, and choosing one
			# ENDS the screen, exactly as it does in the other two
			cName = aEv[2]
			cItem = aEv[3]
			aModel[cName] = cItem
			RppFire(:change, cName, cItem)
			RppFire(:click, cItem, "")
			if $RppClose = 1
				RppFire(:close, "", "")
				return aModel
			ok
			RppFire(:submit, "", "")
			return aModel

		but cWhat = :close
			RppFire(:close, "", "")
			return aModel
		ok
	next
	RppFire(:close, "", "")
	return aModel

### The widget a name belongs to, or [] when the tree has none.
func RppWebFind(aKids, cName)
	nKids = len(aKids)
	for i = 1 to nKids
		oKid = aKids[i]
		cKind = oKid[:kind]
		if cKind != "label" and cKind != "button" and cKind != "status"
			if oKid[:name] = cName
				return oKid
			ok
		ok
	next
	return []

func RppWebButton(aKids, cText)
	nKids = len(aKids)
	for i = 1 to nKids
		if aKids[i][:kind] = "button" and aKids[i][:text] = cText
			return aKids[i]
		ok
	next
	return []

### What the browser sent, in the shape the MODEL holds. A checkbox keeps
### 1 or 0, a table keeps the row NUMBER, a Text keeps [ lines, row, col ]
### with the cursor after the last character (contract 6.1) -- and a
### browser sends a textarea as a list of lines, so the cursor is computed
### here the same way the line renderer computes it.
func RppWebValue(oKid, vVal)
	if len(oKid) = 0
		return vVal
	ok
	cKind = oKid[:kind]
	if cKind = "check"
		return RppTuiYes("" + vVal)
	but cKind = "table"
		return number(vVal)
	but cKind = "text"
		aLines = vVal
		if isstring(vVal)
			aLines = RppWebLines(vVal)
		ok
		if len(aLines) = 0
			aLines = [ "" ]
		ok
		nR = len(aLines)
		nC = len(aLines[nR]) + 1
		aDoc = [ aLines, nR, nC ]
		return aDoc
	ok
	return vVal

### ---------------------------------------------------------- the frame

### The tree as HTML. One page, no framework, no script library: a form
### whose control names ARE the model's keys, so what comes back needs no
### translation table. This is what the socket will serve.
func RppWebHtml(oTree, aModel)
	cOut = "<!doctype html>" + nl
	cOut += "<meta charset=" + char(34) + "utf-8" + char(34) + ">" + nl
	cOut += "<title>" + RppWebEsc(oTree[:title]) + "</title>" + nl
	cOut += "<h1>" + RppWebEsc(oTree[:title]) + "</h1>" + nl
	cOut += "<form method=" + char(34) + "post" + char(34) + ">" + nl
	aKids = oTree[:children]
	nKids = len(aKids)
	for i = 1 to nKids
		cOut += RppWebNode(aKids[i], aModel)
	next
	cOut += "</form>" + nl
	return cOut

### A Row is one line of controls. No width, no columns, no geometry
### (§7.4): the browser decides how much room each gets, exactly as the
### terminal does.
func RppWebRow(oRow, aModel)
	cOut = "<div class=" + char(34) + "row" + char(34) + ">" + nl
	aKids = oRow[:children]
	nK = len(aKids)
	for i = 1 to nK
		cOut += RppWebNode(aKids[i], aModel)
	next
	cOut += "</div>" + nl
	return cOut

func RppWebNode(oKid, aModel)
	cKind = oKid[:kind]
	if cKind = "row"
		return RppWebRow(oKid, aModel)
	but cKind = "label"
		return "<p>" + RppWebEsc(oKid[:text]) + "</p>" + nl
	but cKind = "status"
		return "<p class=" + char(34) + "status" + char(34) + ">" + RppWebEsc(RppStatusText(oKid)) + "</p>" + nl
	but cKind = "button"
		cOut = "<button name=" + char(34) + "press" + char(34)
		cOut += " value=" + RppWebQ(oKid[:text]) + ">"
		cOut += RppWebEsc(oKid[:text]) + "</button>" + nl
		return cOut
	but cKind = "entry"
		return "<input name=" + RppWebQ(oKid[:name]) + " value=" + RppWebQ("" + aModel[oKid[:name]]) + ">" + nl
	but cKind = "check"
		cTick = ""
		if aModel[oKid[:name]] = 1
			cTick = " checked"
		ok
		cOut = "<label><input type=" + char(34) + "checkbox" + char(34)
		cOut += " name=" + RppWebQ(oKid[:name]) + cTick + "> "
		cOut += RppWebEsc(oKid[:label]) + "</label>" + nl
		return cOut
	but cKind = "radio" or cKind = "choice" or cKind = "menu"
		return RppWebOptions(oKid, aModel)
	but cKind = "table"
		return RppWebTable(oKid, aModel)
	but cKind = "text"
		return RppWebText(oKid, aModel)
	ok
	return ""

func RppWebOptions(oKid, aModel)
	aOpts = oKid[:options]
	cNow = "" + aModel[oKid[:name]]
	cKind = oKid[:kind]
	# a menu is a row of buttons: choosing one ENDS the screen, and a
	# button is the control that says so in a browser
	if cKind = "menu"
		cOut = ""
		nOpts = len(aOpts)
		for j = 1 to nOpts
			cPick = "" + oKid[:name] + ":" + aOpts[j]
			cOut += "<button name=" + char(34) + "pick" + char(34)
			cOut += " value=" + RppWebQ(cPick) + ">"
			cOut += RppWebEsc(aOpts[j]) + "</button>" + nl
		next
		return cOut
	ok
	cOut = "<select name=" + RppWebQ(oKid[:name]) + ">" + nl
	nOpts = len(aOpts)
	for j = 1 to nOpts
		cSel = ""
		if aOpts[j] = cNow
			cSel = " selected"
		ok
		cOut += "<option value=" + RppWebQ(aOpts[j]) + cSel + ">" + RppWebEsc(aOpts[j]) + "</option>" + nl
	next
	cOut += "</select>" + nl
	return cOut

func RppWebTable(oKid, aModel)
	aCols = oKid[:columns]
	aRows = oKid[:rows]
	nSel = aModel[oKid[:name]]
	cOut = "<table><tr>"
	nCols = len(aCols)
	for j = 1 to nCols
		cOut += "<th>" + RppWebEsc("" + aCols[j]) + "</th>"
	next
	cOut += "</tr>" + nl
	nRows = len(aRows)
	for r = 1 to nRows
		cMark = ""
		if r = nSel
			cMark = " class=" + char(34) + "sel" + char(34)
		ok
		cOut += "<tr" + cMark + ">"
		for j = 1 to nCols
			cOut += "<td>" + RppWebEsc("" + aRows[r][j]) + "</td>"
		next
		cOut += "</tr>" + nl
	next
	cOut += "</table>" + nl
	return cOut

func RppWebText(oKid, aModel)
	aDoc = aModel[oKid[:name]]
	aLines = aDoc[1]
	cBody = ""
	nLines = len(aLines)
	for i = 1 to nLines
		if i > 1
			cBody += nl
		ok
		cBody += aLines[i]
	next
	cOut = "<textarea name=" + RppWebQ(oKid[:name]) + ">"
	cOut += RppWebEsc(cBody) + "</textarea>" + nl
	return cOut

### HTML escaping, and a quoted attribute. & FIRST, or the escapes
### introduced by the others get escaped again.
func RppWebEsc(cStr)
	cOut = "" + cStr
	cOut = substr(cOut, "&", "&amp;")
	cOut = substr(cOut, "<", "&lt;")
	cOut = substr(cOut, ">", "&gt;")
	cOut = substr(cOut, char(34), "&quot;")
	return cOut

func RppWebQ(cStr)
	return char(34) + RppWebEsc(cStr) + char(34)

### ---------------------------------------------------------- over the socket

### RunWebLive(tree, port) -> the model, when a submit button or a menu
### item ends the screen. The browser renderer with its socket attached:
### the binary serves RppWebHtml()'s page and hands back the form the
### browser posted, and every rule about what that form MEANS is here.
###
### Runs on Ring++ only -- web_serve/web_wait/web_done are builtins in the
### binary -- and is defined here so the library still loads on Ring 1.27,
### exactly as RunKeys is. The scripted RunWeb above needs none of them and
### is what gate 7.2 judges.
func RunWebLive(oTree, nPort)
	$RppEvents = []
	RppResetOn()
	$RppPlain = 1

	aKids = RppFlat(oTree[:children])
	aModel = RppTuiModel(aKids)
	$RppLiveModel = aModel

	if web_serve(nPort) = 0
		? "Ring++: port " + nPort + " is not free"
		return aModel
	ok
	# once per session, not once per screen: a shell calls this for every
	# screen it draws, and five identical banners is what that looked like
	if $RppServing = 0
		$RppServing = 1
		? "Ring++: serving on http://127.0.0.1:" + nPort + "  (Ctrl+C to stop)"
	ok

	while 1
		cHtml = RppWebHtml(oTree, aModel)
		aForm = web_wait(cHtml)
		if len(aForm) = 0
			RppFire(:close, "", "")
			exit
		ok
		$RppLiveModel = aModel

		# 1. the fields, in the order the page carries them. A browser
		#    posts every control, so only a value that DIFFERS is a change.
		cAct = ""
		cActVal = ""
		aSeen = []
		nF = len(aForm)
		for i = 1 to nF
			cK = aForm[i][1]
			cV = aForm[i][2]
			if cK = "press" or cK = "pick"
				cAct = cK
				cActVal = cV
			else
				aSeen + cK
				oKid = RppWebFind(aKids, cK)
				if len(oKid) > 0
					vNew = RppWebValue(oKid, cV)
					if RppTuiSerVal(vNew) != RppTuiSerVal(aModel[cK])
						aModel[cK] = vNew
						RppFire(:change, cK, vNew)
					ok
				ok
			ok
		next

		# 2. an unchecked box is not posted at all, so absence is 0
		nKids = len(aKids)
		for i = 1 to nKids
			oKid = aKids[i]
			if oKid[:kind] = "check"
				cName = oKid[:name]
				if RppWebHas(aSeen, cName) = 0 and aModel[cName] != 0
					aModel[cName] = 0
					RppFire(:change, cName, 0)
				ok
			ok
		next

		# 3. the action that ended the screen
		if cAct = "press"
			oKid = RppWebButton(aKids, cActVal)
			RppFire(:click, cActVal, "")
			if $RppClose = 1
				RppFire(:close, "", "")
				exit
			ok
			if len(oKid) > 0 and oKid[:event] = :submit
				RppFire(:submit, "", "")
				exit
			ok
		but cAct = "pick"
			# "menu:item" -- the menu's name and the item chosen, split at
			# the FIRST colon, so an item containing one survives
			nCut = RppWebColon(cActVal)
			cName = left(cActVal, nCut - 1)
			cItem = RppTuiTail(cActVal, nCut + 1)
			aModel[cName] = cItem
			RppFire(:change, cName, cItem)
			RppFire(:click, cItem, "")
			if $RppClose = 1
				RppFire(:close, "", "")
				exit
			ok
			RppFire(:submit, "", "")
			exit
		ok
	end

	# the listener stays OPEN: a shell calls this once per screen, and a
	# socket closed between screens refuses the browser's redirect. The
	# program ends the session with RppWebBye(), which serves one last
	# page and shuts the socket -- otherwise the browser, still following
	# the redirect, is answered by nothing at all.
	return aModel

### The last page of a session, and the end of the socket. A browser is
### mid-redirect when the final screen returns; without this it is answered
### by a closed port, which reads as a crash rather than an ending.
func RppWebBye(cTitle, cLine)
	cOut = "<!doctype html>" + nl
	cOut += "<meta charset=" + char(34) + "utf-8" + char(34) + ">" + nl
	cOut += "<title>" + RppWebEsc(cTitle) + "</title>" + nl
	cOut += "<h1>" + RppWebEsc(cTitle) + "</h1>" + nl
	cOut += "<p>" + RppWebEsc(cLine) + "</p>" + nl
	cOut += "<p>The window is closed. You can shut this tab.</p>" + nl
	web_bye(cOut)

### A textarea comes back with the browser's own line endings; the model
### holds lines, so the carriage returns go here and nowhere else.
func RppWebLines(cStr)
	aRaw = str2list(cStr)
	aOut = []
	nR = len(aRaw)
	for i = 1 to nR
		cLine = aRaw[i]
		nLen = len(cLine)
		if nLen > 0 and ascii(cLine[nLen]) = 13
			cLine = left(cLine, nLen - 1)
		ok
		aOut + cLine
	next
	return aOut

func RppWebHas(aSeen, cName)
	nS = len(aSeen)
	for i = 1 to nS
		if aSeen[i] = cName
			return 1
		ok
	next
	return 0

### The first colon, or 0.
###
### THIS WAS A LOOP OVER cStr[i] AND IT WAS WRONG (F-54): indexing a string
### gives the character CODE on Ring++ and a one-character STRING on Ring
### 1.27, so `cStr[i] = ":"` was never true on Ring++, the colon was never
### found, and a menu pick wrote to an empty key -- leaving every screen of
### the browser shell reporting the menu's FIRST item, whatever was
### clicked. The terminal renderers never touch this function, so nothing
### else showed it.
###
### substr's two-argument form is the position of a needle, 0 when absent,
### and means the same thing on both runtimes.
func RppWebColon(cStr)
	return substr(cStr, ":")
