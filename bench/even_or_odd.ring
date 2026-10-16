# EvenOrOdd() numbers its answers against its own name.
#
#     ring even_or_odd.ring
#
# The name reads "Even Or Odd". The result is 1 = odd, 2 = even, and the
# documentation confirms it is deliberate: "Result of test (1=odd
# 2=even)".
#
# The only mnemonic a reader has for which number means which is the
# function's own name, and it points the wrong way. Because Ring has no
# boolean (§3.1) the answer must be a number; because 1 and 2 are both
# perfectly good numbers, getting it backwards is silent.
#
# Softanza's answer: OddOrEven(n) returns :Odd or :Even -- a
# self-describing symbol. No mapping to remember, no order to reverse,
# and the name cannot disagree with the result.

load "stdlibcore.ring"

? "EvenOrOdd(17) = " + EvenOrOdd(17) + "   <-- 17 is ODD"
? "EvenOrOdd(18) = " + EvenOrOdd(18) + "   <-- 18 is EVEN"
? ""
? "The name puts Even first. The numbering puts Odd first."
