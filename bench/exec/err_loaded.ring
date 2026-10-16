# An error in a LOADED file names that file as Ring does: the real path of
# its directory, then "/", then its name -- mixed separators on Windows.
load "load_deep/errdep.ring"
? Loaded()
