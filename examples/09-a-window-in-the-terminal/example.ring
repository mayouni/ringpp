# Ring++ example 09 -- a window in the terminal, from a widget tree
#
# THE TASK, which is the first thing a newcomer tries and the first thing
# Ring cannot do without a 9-way choice of GUI bindings: a window with a
# label, a field and a button. The smallest GUI application shipped with
# Ring 1.27 is 259 lines and reaches setGeometry() by line 20.
#
# THIS FILE IS FOUR THINGS AT ONCE, on purpose:
#   an example   -- it runs, unattended, with scripted keys
#   a proof      -- the MODEL must be exactly what the keys said; asserted
#   a gate       -- docs/WIDGET-TREE-CONTRACT.md 7.1: window + input +
#                   button in at most EIGHT lines. Counted below, from
#                   this file's own text, including the scripted-keys line
#                   a real program would not need. Nine fails the build.
#   the contract -- 7.2 says two renderers fed the same keys must leave
#                   byte-identical model state. There is one renderer so
#                   far; this is the model it must match, and the harness.
#
# WHERE IT IS HONEST ABOUT ITS LIMITS: the renderer is line-driven. Raw
# keys on a live Windows console are gate 3 and are not verified, so a
# field is a line and a button is Enter. That is the prototype, said so.
#
# Run it:  ring examples/09-a-window-in-the-terminal/example.ring

load "../../ringpp.ring"

? "Ring++ example 09 -- a window in the terminal"
? copy("-", 58)
? ""

#8LINES-BEGIN
ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])
$RppKeys = [ "amina", "" ]
m = Run(ui)
? "hello " + m[:name]
#8LINES-END

### ---------------------------------------------------------------- the gate

# 1. the model is exactly what the keystrokes said
if m[:name] != "amina"
	raise("MODEL MISMATCH: expected amina, got '" + m[:name] + "'")
ok
aE = $RppEvents

# 0. THE 7.2 HARNESS: the same tree, the same keys, run again -- and the
#    model and the event log must be BYTE-IDENTICAL to the first run. With
#    one renderer this proves the renderer is deterministic; when a second
#    renderer exists it takes this second slot, and the same line judges it.
#    Serialised by hand into one string each, so `=` compares bytes.
$RppKeys = [ "amina", "" ]
m2 = Run(ui)
aE2 = $RppEvents
cA = RppSerialise(m, aE)
cB = RppSerialise(m2, aE2)
# the line bench/tui72.py (rnx-spike) compares against keys.ring's, run
# on Ring++: the same session through the keystroke renderer
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

# 2. the events are exactly the three the keys imply, in order
if len(aE) != 3
	raise("EVENT COUNT: expected 3, got " + len(aE))
ok
if aE[1][1] != "change" or aE[1][2] != "name" or aE[1][3] != "amina"
	raise("EVENT 1 wrong: " + aE[1][1] + " " + aE[1][2] + " " + aE[1][3])
ok
if aE[2][1] != "click" or aE[2][2] != "OK"
	raise("EVENT 2 wrong: " + aE[2][1] + " " + aE[2][2])
ok
if aE[3][1] != "submit"
	raise("EVENT 3 wrong: " + aE[3][1])
ok

# 3. the eight-line gate, measured from this file's own text
cSrc = read("example.ring")
aLines = str2list(cSrc)
nLines = len(aLines)
nCount = 0
bIn = 0
for i = 1 to nLines
	cL = trim(aLines[i])
	if cL = "#8LINES-BEGIN"
		bIn = 1
	but cL = "#8LINES-END"
		bIn = 0
	but bIn = 1 and len(cL) > 0 and left(cL, 1) != "#"
		nCount++
	ok
next

? ""
? "events   : " + len(aE) + "  (change, click, submit)"
? "model    : name = " + m[:name]
? "lines    : " + nCount + " of Ring for window + label + entry + button, scripted keys included"
? "gate     : at most 8"
if nCount > 8
	raise("EIGHT-LINE GATE FAILED: " + nCount + " lines")
ok
? ""
? "EXAMPLE 09 OK"
