# The same window, LIVE: no scripted keys, your keyboard, your console.
#
#   Run it:  ring examples/09-a-window-in-the-terminal/live.ring
#
# Type a name and press Enter; then press Enter on the OK button. The
# renderer is line-driven in this prototype (contract gate 3 is not yet
# measured), so every field is a line and every button is Enter.
#
# WHAT TO LOOK FOR. In Windows Terminal the screen clears and the window
# repaints in place as you type. If instead you see literal characters
# such as  <-[2J  or  ?[1m  at the top, your console is not interpreting
# escape sequences -- that is exactly the case the console probe exists to
# measure, and it is worth telling me which console you used.

load "../../ringpp.ring"

ui = Window("Sign in", [
	Label("Name"),
	Entry(:name),
	Button("OK", :submit) ])
m = Run(ui)
? "hello " + m[:name]
