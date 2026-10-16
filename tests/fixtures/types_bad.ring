# Fixture for the T2 type gate. Every defect below was verified against
# Ring 1.27 itself before the rule was written -- this file is not a
# statement of what we believe, it is a record of what Ring does.
#
#   Sum(1,2,3)     -> Error (R20) : Calling function with extra number of parameters
#   Greet()        -> Error (R19) : Calling function with less number of parameters
#   int func       -> Error (R24) : Using uninitialized variable: int   (no load here)
#   Sum("a","b")   -> runs, returns "ab". Ring never checks the annotation.
#
# Do not "fix" this file. tests/run-all.ps1 asserts each rule fires on it.

? Sum("a", "b")     # rpp/type-arg-mismatch  x2
? Sum(1, 2, 3)      # rpp/type-arity         R20
? Greet()           # rpp/type-arity         R19
? Greet(42)         # rpp/type-arg-mismatch

int func Sum(int x, int y)     # rpp/type-hints-missing  R24
    return x + y

func Greet(string s)
    return s

func Flag(bool b)              # rpp/type-not-a-hint     boolean
    return b
