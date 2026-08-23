# Fixture for `ringpp deps` (phase B1): the control.
#
# No load, so no native library can be reached, so this program really is
# one .ringo plus a runtime -- and that is portable between x64 platforms.
# It exists so the happy path cannot be satisfied by a tool that simply
# never finds anything.

func Main
	? "pure"
