# Fixture for `ringpp deps` (phase B1). Its whole job is to `load` something
# whose closure reaches a native extension.
#
# `load "stdlib.ring"` pulls in six database and network extensions to offer
# upper(). On Windows their absence is silently tolerated; on Linux the first
# one raises Error (R38) and stops the program -- which is how B0 found this
# by running it (FINDINGS F-29). `ringpp deps` must name libring_odbc.so
# WITHOUT running anything.

load "stdlib.ring"

func Main
	? upper("x")
