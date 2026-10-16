load "typehints.ring"

# The other half of the gate, and the more important one: correct code must
# produce NOTHING. A checker that cries wolf is worse than no checker.
#
# Ring's one-line class form is here on purpose. It puts an attribute exactly
# where a return annotation goes, and the first version of the checker read
# `z` as a type and reported R24 on this shape -- in Ring's own samples.
# FINDINGS F-24.

? Sum(1, 2)
? Greet("hello")

int func Sum(int x, int y)
    return x + y

func Greet(string s)
    return s

func Take(stzString oS)     # a class as a type: typehints registers those
    return oS

Class Point x y z func print see x + nl + y + nl + z + nl
