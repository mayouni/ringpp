# Ring++ example 13, the SECOND renderer: the same text driven by KEYS.
#
# Runs on Ring++ only. Two sessions, gated two ways (contract 6.5):
#
#   1. THE SHARED SESSION -- a b c Enter d e f Tab, then Enter on OK --
#      is what example.ring types as lines on Ring 1.27, and its serial
#      must be byte-identical: gate 7.2, compared by rnx-spike's
#      bench/tui72.py.
#   2. A KEYSTROKE-ONLY SESSION -- cursor movement into the middle of a
#      line, Home, End, Delete -- has no line-driven equivalent, so 7.2
#      cannot judge it and does not pretend to. It is judged by
#      deterministic replay (the same keys twice, byte-identical) AND
#      against a result worked out by hand below, so the editing rules
#      of 6.4 are asserted, not just repeated.
#
# Live: empty $RppKeys and run it with rnxc exec. Type, Enter breaks the
# line, arrows move the cursor, Backspace and Delete edit, Home and End
# jump, Tab leaves the editor for OK, Enter on OK submits, Esc closes.
#
#   Run it:  rnxc exec examples/13-a-text-to-edit/keys.ring

load "../../rpp/tui.ring"

$ui = Window("Edit", [
	Label("Notes"),
	Text(:doc),
	Button("OK", :submit) ])

# ---- 1. the shared session -----------------------------------------
$RppKeys = [ "a", "b", "c", "<enter>", "d", "e", "f", "<tab>", "<enter>" ]
$m = RunKeys($ui)
$cShared = RppSerialise($m, $RppEvents)

# ---- 2. the keystroke-only session, worked out by hand --------------
#   a b c Enter d e f     -> [ "abc", "def" ]  cursor 2:4
#   Up                    -> row 1, column carried: 1:4
#   Home Right            -> 1:2
#   X                     -> "aXbc"  1:3
#   Backspace             -> "abc"   1:2   (deletes the X before the cursor)
#   Y                     -> "aYbc"  1:3
#   Down                  -> 2:3
#   End                   -> 2:4
#   Backspace             -> "de"    2:3
#   Left                  -> 2:2
#   Delete                -> "d"     2:2   (deletes the e AT the cursor)
#   Tab, Enter            -> leave with [ "aYbc", "d" ] at 2:2; OK
$aOnly = [ "a", "b", "c", "<enter>", "d", "e", "f", "<up>", "<home>", "<right>", "X",
           "<backspace>", "Y", "<down>", "<end>", "<backspace>", "<left>", "<delete>",
           "<tab>", "<enter>" ]
$RppKeys = $aOnly
$m1 = RunKeys($ui)
$cOnlyA = RppSerialise($m1, $RppEvents)
$RppKeys = $aOnly
$m2 = RunKeys($ui)
$cOnlyB = RppSerialise($m2, $RppEvents)
$cWant = "model:doc=2,2,aYbc" + $RppBsN + "d|events:change,doc,2,2,aYbc" + $RppBsN + "d|click,OK,|submit,,|"

? ""
$nOk = 1
if $cOnlyA != $cWant
	? "KEYS FAIL: keystroke-only session differs from the hand-worked result"
	? "  got  [" + $cOnlyA + "]"
	? "  want [" + $cWant + "]"
	$nOk = 0
ok
$nReplay = 0
if $cOnlyA = $cOnlyB
	$nReplay = 1
ok
? "replay identical : " + $nReplay
if $nReplay = 0
	? "KEYS FAIL: the same keys twice gave different transcripts"
	$nOk = 0
ok
if $nOk = 1
	? "serial: " + $cShared
	? "serial2: " + $cOnlyA
ok
? "KEYS DONE"
