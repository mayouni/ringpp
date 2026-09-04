# The editor in a BROWSER, live. Ring++ only.
#
#   Run it:   rnxc exec examples/13-a-text-to-edit/web_live.ring
#   Open it:  http://127.0.0.1:8772
#
# The Text widget is a <textarea>. Type several lines and press OK: the
# model is [ lines, row, col ] with the cursor after the last character,
# exactly as the terminal renderers leave it (contract 6.1), and the
# browser's own line endings are stripped on the way in.

load "../../rpp/tui.ring"

$ui = Window("Edit", [
	Label("Notes"),
	Text(:doc),
	Button("OK", :submit) ])

$m = RunWebLive($ui, 8772)
$aDoc = $m[:doc]
RppWebBye("Saved", "" + len($aDoc[1]) + " line(s), cursor " + $aDoc[2] + ":" + $aDoc[3])
? ""
? "lines: " + len($aDoc[1]) + "   cursor: " + $aDoc[2] + ":" + $aDoc[3]
? "serial: " + RppSerialise($m, $RppEvents)
