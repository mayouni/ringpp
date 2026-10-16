# The keystroke renderer, LIVE: your keyboard, your console, Ring++ only.
#
#   Run it:  rnxc exec examples/09-a-window-in-the-terminal/keys_live.ring
#
# Type a name -- it appears in the field as you type; Backspace deletes.
# Enter moves to the OK button, Enter again submits, Esc closes.
#
# WHAT THIS PROVES, in a plain cmd.exe window especially: the console
# probe found VT processing OFF by default there, and Ring 1.27 cannot
# switch it on -- so the line renderer prints literal escape characters
# in that window. This renderer calls tui_init() first, which switches it
# on from inside the binary. If the window repaints cleanly here, the
# design's central claim is proven: the binary fixes the console, not the
# program. keys.ring is the same session scripted, for the 7.2 gate.

load "../../rpp/tui.ring"

$ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])
$m = RunKeys($ui)
? "hello " + $m[:name]
