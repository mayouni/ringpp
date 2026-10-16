# Ring resolves a load by WHICH FILE it sits in -- three probes on
# 2026-09-10 to pin it down, after two wrong guesses in one afternoon:
#
#   the ROOT file's loads resolve against the CURRENT DIRECTORY;
#   a LOADED file's loads resolve against ITS OWN directory.
#
# This probe is the second half. load_deep/mid.ring says `load "leaf.ring"`
# and leaf.ring sits beside it, NOT in the cwd -- so it only resolves if a
# loaded file's loads are relative to itself. Softanza is built on this:
# base/stzBase.ring says `load "common/stzFuncs.ring"` and is loaded from
# two directories up. Resolving everything against the cwd made the whole
# corpus load nothing while the census still said `ok`.
? "A before"
load "load_deep/mid.ring"
? "C after, and mid set $g to " + $g
