# `see` and `put` print WITHOUT a newline, in any case of letters; only `?`
# prints one. Measured on the oracle and on the official 1.27, byte for byte,
# and read off Ring's own parser (vendor/ring-vm/src/stmt.c:382, one branch
# for K_SEE | K_PUT, and :392 for the `?` that also pushes a newline).
#
# rnxc decided the flag by comparing the statement's first word with the
# lowercase string "see", so `SEE`, `See` and every `put` printed a line:
# Ring's own library, which writes `See " = " + Sum + nl`, double-spaced.
# Found 2026-10-04 by the code-graph court (haro/FINDINGS.md HF-74), which
# could not tell the two spellings apart without running the oracle.
#
# Every row below ends in `see "|"` so a missing or extra newline shows in
# the next row's first column.

SEE "a"
see "b"
See "c"
sEe "d"
see "|"
? ""
PUT "e"
put "f"
Put "g"
see "|"
? ""
? "h"
see "|"
? ""

# an expression after the keyword, `nl` among it, the way the estate writes it
See "x=" + 1 + nl
put "y=" + 2 + nl
see "|"
? ""

# inside a function, and after a branch: the flag is a property of the
# statement, not of where it stands. (The function comes last: whatever is
# written after a `func` is part of its flow.)
Say("z")
if true
	PUT "p"
	SEE "q"
	? "r"
ok

func Say(x)
	Put x
	See x
	? x
