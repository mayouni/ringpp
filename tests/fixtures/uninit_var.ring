# Fixture for rpp/uninitialized-variable (F-47). Self-contained: no loads,
# no eval, parses clean -- the universe gates must all hold here.
#
# Every defect below is deliberate. Do not "fix" this file.

gMode = "loose"
Run()

func Run
    nTotal = 5
    # One-letter typo of the local above: R24 when reached, invisible to
    # review because identifiers are case-insensitive (F-18).
    ? nTotl

    # Every one of these must stay SILENT:
    ? gMode              # a main-scope global
    ? nTotal             # the local, spelled right
    ? nl + sysargv[1]    # predefined variables
    for k = 1 to 2
        ? k              # loop variable
    next
    o = new Tool { Fire() }   # object-scope brace body
    ? o

class Tool
    func Fire
        ? "fired"
