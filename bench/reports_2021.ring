# Four defects reported to the Ring group in early 2021, re-run on 1.27.
#
#     ring reports_2021.ring
#
# The file-name half of the January 2021 error-location report was fixed
# within 24 hours, with the commit cited in the thread. These four were
# acknowledged and are still open five and a half years later.
#
# Nested block comments are demonstrated separately -- a file containing
# the failure cannot also run: see reports_2021_comments.ring.

load "stdlib.ring"

? "=== 1. the range operator, reported Jan 2021"
? '  1:12      -> type ' + type(1:12) + ", len " + len(1:12)
? '  "a":"e"   -> type ' + type("a":"e") + ", len " + len("a":"e")
c = "1":"12"
? '  "1":"12"  -> type ' + type(c) + ', value [' + c + ']   <-- a STRING, silently'
? '  ("I will revise this to present a clear runtime error message", Jan 2021)'

? ""
? "=== 2. list2code on a list holding objects, reported Feb 2021"
o1 = new Person
o2 = new Person
? "  list2code([5, 2, o1, 3, o2]) ->"
? "  " + list2code([ 5, 2, o1, 3, o2 ])
? "  the objects are EMPTY SLOTS, and the result is not valid Ring"

? ""
? "=== 3. where an unclosed literal is reported"
? "  see reports_2021_literal.ring -- the quote opens on line 8 of 12"
? "  and the error says line 12: the END OF FILE, not the literal."
? "  In a 720-line file the same test reports line 720 for a literal"
? "  opening on line 700 -- the error grows with the file."

? ""
? "=== 4. Unicode does NOT shift line numbers -- the belief does not reproduce"
? "  runtime error on line 20: reported line 20, with ASCII and with Arabic"
? "  syntax error on line 20: reported line 21 in both (parser look-ahead)"

class Person
    name
    age
