# Ring++ example 13 -- a text to edit, from a widget tree
#
# THE TASK: the contract's hard widget, `Text`, built to the model shape
# fixed in docs/WIDGET-TREE-CONTRACT.md 6.1 BEFORE either renderer was
# written: [ aLines, nRow, nCol ] -- the buffer as a list of lines, the
# cursor as a row and the column BEFORE which it sits. That shape is the
# one thing gate 7.2 cannot check after the fact, which is why it was
# written down first and is asserted here, field by field.
#
# THE LINE-DRIVEN EDIT (6.4): one prompt per line, a blank line ends the
# field, the cursor ends after the last character of the last line. So
# the lines "abc", "def", "" leave [ "abc", "def" ] with the cursor at
# 2:4 -- and a b c Enter d e f Tab under the keystroke renderer leaves the
# same, which is what makes Text gateable at all.
#
# Run it:  ring examples/13-a-text-to-edit/example.ring

load "../../ringpp.ring"

? "Ring++ example 13 -- a text to edit"
? copy("-", 58)
? ""

ui = Window("Edit", [
	Label("Notes"),
	Text(:doc),
	Button("OK", :submit) ])
$RppKeys = [ "abc", "def", "", "" ]
m = Run(ui)
aDoc = m[:doc]
? "lines: " + len(aDoc[1]) + "   cursor: " + aDoc[2] + ":" + aDoc[3]

### ---------------------------------------------------------------- the gate

# 1. the model shape of contract 6.1, field by field
aLines = aDoc[1]
if len(aLines) != 2 or aLines[1] != "abc" or aLines[2] != "def"
	raise("LINES WRONG: " + RppSerialise(m, $RppEvents))
ok
if aDoc[2] != 2 or aDoc[3] != 4
	raise("CURSOR WRONG: expected 2:4, got " + aDoc[2] + ":" + aDoc[3])
ok
aE = $RppEvents

# 2. three events: one change carrying the whole value, a click, a submit
if len(aE) != 3
	raise("EVENT COUNT: expected 3, got " + len(aE))
ok
if aE[1][1] != "change" or aE[1][2] != "doc" or len(aE[1][3][1]) != 2
	raise("EVENT 1 wrong: " + aE[1][1] + " " + aE[1][2])
ok
if aE[2][1] != "click" or aE[3][1] != "submit"
	raise("EVENT 2/3 wrong: " + aE[2][1] + " " + aE[3][1])
ok

# 3. the serialisation of 6.1, byte for byte
cA = RppSerialise(m, aE)
cWant = "model:doc=2,4,abc" + $RppBsN + "def|events:change,doc,2,4,abc" + $RppBsN + "def|click,OK,|submit,,|"
if cA != cWant
	raise("SERIAL WRONG: [" + cA + "] want [" + cWant + "]")
ok

# 4. the same session twice, byte-identical
$RppKeys = [ "abc", "def", "", "" ]
m2 = Run(ui)
cB = RppSerialise(m2, $RppEvents)
? "serial: " + cA
nSame = 0
if cA = cB
	nSame = 1
ok
? ""
? "identical output : " + nSame
if nSame = 0
	raise("TWO RUNS DIFFER: [" + cA + "] vs [" + cB + "]")
ok

# 5. an empty edit is one empty line with the cursor at 1:1, never []
$RppKeys = [ "", "" ]
m3 = Run(ui)
if len(m3[:doc][1]) != 1 or m3[:doc][1][1] != "" or m3[:doc][2] != 1 or m3[:doc][3] != 1
	raise("EMPTY BUFFER WRONG: " + RppSerialise(m3, $RppEvents))
ok

? 'model    : 2 lines, cursor 2:4; an empty edit is [""] at 1:1'
? ""
? "EXAMPLE 13 OK"
