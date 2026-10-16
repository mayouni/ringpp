# Fixture for rpp/unknown-class (F-48). Self-contained: no loads, no eval,
# parses clean. Every defect below is deliberate. Do not "fix" this file.

# One-letter typo of Widget below: R11 the moment this line runs.
o1 = new Widgett

# `new` over a FUNCTION name: still R11 (verified) -- functions are not
# classes, whatever the name says.
o2 = new Maker

# NOT defects, and each must stay silent:
o3 = new Widget            # the class, spelled right
w  = new Widget { Poke() } # brace body resolves against the object

class Widget
    a = 1

# Typo of a parent that exists nowhere: the file LOADS AND RUNS fine, and
# R15 fires only when Broken is first instantiated -- the quiet one.
class Broken from Missng
    b = 2

func Maker
    return 1
