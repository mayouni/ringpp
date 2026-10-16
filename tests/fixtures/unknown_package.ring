# Fixture for rpp/unknown-package (F-48). Self-contained: no loads, no
# eval, parses clean. Every defect below is deliberate. Do not "fix" it.

# One-letter typo of Sys.Web below: R25 the moment this line runs --
# verified to ship silently in dead code and to raise inside functions too.
import Syz.Web

# NOT defects:
import Sys.Web       # the package, spelled right, full dotted match
o = new C
? type(o)

package Sys.Web
    class C
        x = 1
