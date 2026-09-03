# The text editor, LIVE: your keyboard, your console, Ring++ only.
#
#   Run it:  rnxc exec examples/13-a-text-to-edit/keys_live.ring
#
# Type; Enter breaks the line (contract 6.4 -- inside a Text, Enter is a
# line break and Tab leaves). The arrows move the cursor in two
# dimensions, Backspace and Delete edit, Home and End jump within the
# line. The header shows the line count and the cursor as row:col; the
# window shows six lines and follows the cursor -- that scrolling is the
# renderer's and is stored nowhere (contract 6.2). Tab leaves the editor
# for OK, Enter on OK submits, Esc closes.

load "../../rpp/tui.ring"

$ui = Window("Edit", [
	Label("Notes"),
	Text(:doc),
	Button("OK", :submit) ])
$m = RunKeys($ui)
$aDoc = $m[:doc]
? "lines: " + len($aDoc[1]) + "   cursor: " + $aDoc[2] + ":" + $aDoc[3]
