# Ring++ example 15 -- a row of buttons, and the gate that layout is free
#
# THE TASK: `Row`, the last widget of the contract's first tranche, and
# the only one that is pure LAYOUT. Which makes its gate the sharpest in
# the set:
#
#   THE SAME SESSION ON A TREE WITH A ROW AND THE SAME TREE WITHOUT ONE
#   MUST LEAVE BYTE-IDENTICAL MODEL AND EVENTS.
#
# Layout is drawing; drawing is invisible to the model. So every renderer
# flattens the tree for the model, the focus ring and the events, and only
# the drawing walks the nesting. If a Row could move a transcript it would
# not be layout, it would be behaviour, and this example would fail.
#
# ROW PROMISES NOTHING ABOUT WIDTH (contract 7.4). It says "these belong
# together, side by side"; how much room each child gets is the
# renderer's, exactly as the scrollport is (6.2). There is no width
# parameter and there will not be one.
#
# Run it:  ring examples/15-a-row-of-buttons/example.ring

load "../../ringpp.ring"

? "Ring++ example 15 -- a row of buttons"
? copy("-", 58)
? ""

# the same widgets, twice: once in a Row, once stacked
uiRow = Window("Confirm", [
	Label("Name"),
	Entry(:name),
	Row([ Button("OK", :submit), Button("Cancel", :close) ]) ])

uiFlat = Window("Confirm", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit),
	Button("Cancel", :close) ])

$RppKeys = [ "amina", "" ]
mRow = Run(uiRow)
cRow = RppSerialise(mRow, $RppEvents)

$RppKeys = [ "amina", "" ]
mFlat = Run(uiFlat)
cFlat = RppSerialise(mFlat, $RppEvents)

? ""
? "serial: " + cRow

### ---------------------------------------------------------------- the gate

# 1. THE POINT OF THE WIDGET: a Row changed the drawing and nothing else
if cRow != cFlat
	raise("A ROW MOVED THE TRANSCRIPT:" + nl + "  row  " + cRow + nl + "  flat " + cFlat)
ok

# 2. and the session did what the lines said
if mRow[:name] != "amina"
	raise("MODEL WRONG: " + cRow)
ok
aE = $RppEvents
if len(aE) != 3
	raise("EVENT COUNT: expected 3, got " + len(aE))
ok
if aE[1][1] != "change" or aE[2][1] != "click" or aE[3][1] != "submit"
	raise("EVENT ORDER: " + aE[1][1] + " " + aE[2][1] + " " + aE[3][1])
ok

# 3. the same session twice, byte-identical
$RppKeys = [ "amina", "" ]
m2 = Run(uiRow)
cB = RppSerialise(m2, $RppEvents)
nSame = 0
if cRow = cB
	nSame = 1
ok
? ""
? "identical output : " + nSame
if nSame = 0
	raise("TWO RUNS DIFFER")
ok

? "row = flat : the transcript is the same with the Row and without it"
? ""
? "EXAMPLE 15 OK"
