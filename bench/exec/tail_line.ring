# F-114: a statement whose last operand is a postfix construct -- a[i], f(),
# (x), o.v -- is finished AFTER Ring's parser has passed the newline behind
# it (looking for a `.` that continues the chain), so the operator that
# completes it reports the line of the NEXT token: here the `?` three lines
# down, the blank line and the comments passed.
aL = ["abc"]
x = 0 + aL[1]

# a comment
// and another
? "next"
