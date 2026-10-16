# F-109: a loaded file that does not SCAN -- here a block comment never
# closed -- refuses the program before anything runs, as a missing load does
# (C-25): the scanner's S2 report naming the file and the line the comment
# OPENED on, "Called from other source code file", then this file's C27 at
# the load's line and its error count, exit 1. In the loaded file a quote in
# a comment and a comment marker in a literal are nothing, as on Ring.
# rnxc used to compile the file as far as the grammar could read it and run.
? "before the load -- never printed, on Ring or on Ring++"
load "scan_bad_lib/bad.ring"
? "after the load -- never printed"
