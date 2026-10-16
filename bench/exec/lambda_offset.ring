load "lambda_offset_lib/lib.ring"
fTwoPaddedToByte = func t { return "two" }
fOne = LibOne()
? call fOne(1)
? call fTwoPaddedToByte(1)

# TWO FILES WITH A LAMBDA AT THE SAME BYTE -- found 2026-10-05, by a Softanza program that called a method nothing in it calls.
#
# lambda_offset_lib/lib.ring (loaded on line 1) puts `q = func t { ... }` (inside LibOne) at exactly the byte where line 2 here puts `fTwoPaddedToByte = func t { ... }`: both files'
# first line is as long as the `load` statement, so the lambdas start together. The compiler looked a lambda up by its byte offset ALONE across every file of
# the unit, so the two lambdas were one: both calls ran the same one and printed the same word. Ring answers "one" then "two".
#
# It was not the file's header comments, as it first seemed -- any byte moved (one newline) moved the lambda off the colliding offset -- and it was not the VM.
# In the reproduction (haro/spike/v20/probes/nodesids.ring, a Softanza program) a derivation lambda at byte 2557 of the script was resolved to a lambda at byte
# 2557 of base/security/stzSecurityRule.ring, `func oGraph { _r_ = [] _a_ = oGraph.NodesIds() ...}`, and R14 reported the method that lambda calls on the stzRefinableCode it was handed.
# Fixed with bc47ddb, which was written for lambdas in re-read statements and made the lookup match the file as well as the offset -- for every lambda.
# On the build before it, this probe prints "one" twice; shift either lambda by one byte (a space after the `load`) and it answers "one", "two".
