# `func MAIN` IS Main. Ring folds identifiers, so the name it looks for is
# matched without regard to case -- probed as `main`, `Main` and `MAIN`,
# all three called. It is the same rule that makes `N` and `n` one
# variable (F-18), applied to the one name the runtime itself looks up.
#
# The arity row belongs here too and cannot be tested against the oracle:
# a Main that declares parameters is called with NONE and raises
#     Error (R19) : Calling function with less number of parameters
# at the `func Main` line (m7 in scratchpad/mainp). Reproduced, but it
# ends the program, so it is measured there rather than pinned here.

? "-- the top level, then MAIN in capitals --"

func MAIN
	? "  MAIN ran"
	? "done"
