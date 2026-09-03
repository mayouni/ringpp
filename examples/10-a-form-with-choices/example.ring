# Ring++ example 10 -- a form with choices, from a widget tree
#
# THE TASK: the next three widgets of the contract -- a check box, a radio
# group and a choice list -- in the same tree as example 09, judged the
# same way. The model holds 1 or 0 for the check and the chosen option's
# TEXT for the other two; a line of "y" ticks the box and a digit picks
# an option, so the same digits typed as a line here or as keys under the
# keystroke renderer leave the same model. That is what keeps contract
# gate 7.2 honest across the two renderers.
#
# Two corrections to the contract's vocabulary, both for the same reason:
# `input` and `list` are Ring builtins, and a user function replaces a
# builtin process-wide -- so the widgets are Entry and Choice.
#
# Run it:  ring examples/10-a-form-with-choices/example.ring

load "../../ringpp.ring"

? "Ring++ example 10 -- a form with choices"
? copy("-", 58)
? ""

ui = Window("Sign up", [
	Label("Name"),
	Entry(:name),
	Checkbox(:remember, "Remember me"),
	Radio(:color, [ "Red", "Green", "Blue" ]),
	Choice(:city, [ "Cairo", "Tunis", "Niamey" ]),
	Button("OK", :submit) ])
$RppKeys = [ "amina", "y", "2", "3", "" ]
m = Run(ui)
? "hello " + m[:name] + " from " + m[:city]

### ---------------------------------------------------------------- the gate

# 1. the model is exactly what the lines said
if m[:name] != "amina" or m[:remember] != 1 or m[:color] != "Green" or m[:city] != "Niamey"
	raise("MODEL MISMATCH: " + RppSerialise(m, $RppEvents))
ok
aE = $RppEvents

# 2. six events, in order: four changes, a click, a submit
if len(aE) != 6
	raise("EVENT COUNT: expected 6, got " + len(aE))
ok
if aE[2][1] != "change" or aE[2][2] != "remember" or aE[2][3] != 1
	raise("EVENT 2 wrong: " + aE[2][1] + " " + aE[2][2] + " " + aE[2][3])
ok
if aE[3][3] != "Green" or aE[4][3] != "Niamey"
	raise("EVENT 3/4 wrong: " + aE[3][3] + " " + aE[4][3])
ok
if aE[5][1] != "click" or aE[6][1] != "submit"
	raise("EVENT 5/6 wrong: " + aE[5][1] + " " + aE[6][1])
ok

# 3. the 7.2 harness, one renderer twice: byte-identical model and events
$RppKeys = [ "amina", "y", "2", "3", "" ]
m2 = Run(ui)
cA = RppSerialise(m, aE)
cB = RppSerialise(m2, $RppEvents)
# compared against keys.ring's line, run on Ring++, by rnx-spike bench/tui72.py
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

? "events   : " + len(aE) + "  (change x4, click, submit)"
? "model    : " + m[:name] + ", remember " + m[:remember] + ", " + m[:color] + ", " + m[:city]
? ""
? "EXAMPLE 10 OK"
