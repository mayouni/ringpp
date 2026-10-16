# RING CALLS Main() AFTER THE TOP LEVEL, and Ring++ did not.
#
# world/world_contract printed NOTHING here and 84 lines on the oracle --
# its whole body is inside `func Main`, so all we ran were its two `load`
# statements, and the runtime then said "TOP LEVEL RAN TO COMPLETION",
# which was true and useless.
#
# Twelve rows measured on 1.27 before any of it was written, in
# scratchpad/mainp. The four that decide the shape of the fix:
#
#   the top level runs FIRST and Main after it -- so this is a call
#       appended to the entry, not a different entry point
#   `func main`, `func Main` and `func MAIN` are all it -- Ring folds
#       names, so the match is case-insensitive (auto_main_case.ring)
#   a METHOD named Main is NOT called -- row 3 below
#   `In function main()` is printed for an error inside it, and the frame
#       that called it reports the `func Main` LINE, in Main's own file --
#       rows 4 and 5, and the reason main_fn carries a sentinel rather
#       than naming Main when a file has no top level at all
#
# Two more are pinned elsewhere because one file cannot hold them: a Main
# defined in a LOADED file is called just the same (m5), and a file that
# is nothing but `func Main` is a program (auto_main_only.ring). Two of
# them in one unit is Ring's C22 redefinition, a rule of its own that we
# do not implement and that this probe therefore stays clear of.

? "-- 1. the top level runs FIRST --"
? "  top level"

func Main
	? ""
	? "-- 2. and Main() runs after it, with no arguments --"
	? "  Main ran"

	? ""
	? "-- 3. a METHOD of that name is not it --"
	o = new K
	? "  K was built and its Main did not run"

	? ""
	? "-- 4. the chain names main(), and stops at the file --"
	Boom()

func Boom
	raise("from inside Main")

class K

	def Main
		? "  a METHOD named Main ran -- it must not"
