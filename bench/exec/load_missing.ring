# F-101: a load that names a file nobody can open stops the program before
# ANYTHING runs -- the line above it included -- with E9, a C27 at the load's
# line, each file's error count, and exit 1. Ring reports while parsing,
# depth first: the child's own missing load and its count come before the
# C27 the child costs this file. rnxc used to print a note and run on.
? "before the loads -- never printed, on Ring or on Ring++"
load "load_missing_lib/child.ring"
load "no_such_file_anywhere.ring"
? "after the loads -- never printed"
