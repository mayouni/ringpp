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

### ---------------------------------------------------------- the tree

func Window cTitle, aChildren
	return [ :kind = "window", :title = cTitle, :children = aChildren ]

func Label cText
	return [ :kind = "label", :text = cText ]

func Entry cName
	return [ :kind = "entry", :name = cName ]

func Button cText, cEvent
	return [ :kind = "button", :text = cText, :event = cEvent ]

### ---------------------------------------------------------- the renderer

### Run(tree) -> the model, when the submit button is pressed or the
### children are exhausted. No callback in this first cut: Ring 1.27's
### anonymous functions see only globals (measured, charter 4e), so a
### handler that needs the model would need the model to be global. The
### program reads what Run() returns, and $RppEvents for the history.
func Run oTree
	$RppEvents = []
	$RppPlain  = 0
	if len($RppKeys) > 0
		$RppPlain = 1
	ok

	aKids = oTree[:children]
	nKids = len(aKids)

	# every Entry exists in the model BEFORE any read (F-49)
	aModel = []
	for i = 1 to nKids
		if aKids[i][:kind] = "entry"
			aModel + [ aKids[i][:name], "" ]
		ok
	next

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

### One line of input: the next scripted line if there is one, echoed so
### a transcript reads like a session; otherwise the keyboard.
func RppTuiRead cPrompt
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
func RppTuiDraw oTree, aModel
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
		but cKind = "button"
			see "  ( " + oKid[:text] + " )" + nl
		ok
	next
	see nl

### ---------------------------------------------------------- the 7.2 harness

### One string for a model and an event log, built by hand so a plain `=`
### compares BYTES. Contract 7.2: two renderers fed the same keys must
### leave byte-identical model state -- this is the string that is compared.
func RppSerialise aModel, aEvents
	cOut = "model:"
	nM = len(aModel)
	for i = 1 to nM
		cOut += aModel[i][1] + "=" + aModel[i][2] + "|"
	next
	cOut += "events:"
	nE = len(aEvents)
	for i = 1 to nE
		cOut += aEvents[i][1] + "," + aEvents[i][2] + "," + aEvents[i][3] + "|"
	next
	return cOut
