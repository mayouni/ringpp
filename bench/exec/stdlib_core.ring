# RING'S OWN stdlibcore UNDER RULE A.
#
# stdlib.rh defines nine globals at its top level and stdlibcore's functions
# read them BARE -- Sleep() reads C_SECONDSIZE, List2Code() keeps its
# indent in List2CodeTabsCounter, RandomList() raises C_ERROR_EXPECTLIST.
# Under Rule A a bare name in a function is that function's local, so
# Ring++ refused all eight functions and every row below raised, sleep()
# and list2code() among them -- about twenty live sites in Softanza.
#
# rnxc installs rpp/stdlib in place of the two vendored files: Ring's text
# with the seventeen reads made `$` and each constant defined under both
# names, every line number unchanged. The oracle loads Ring's own files, so
# this probe compares the two; the copies were also run ON RING (both
# builds, the same eleven answers) before they were installed. 2026-09-27.

load "stdlibcore.ring"

try sleep(0.01) ? "01 sleep: ok" catch ? "01 sleep: " + cCatchError done
try ? "02 list2code: " + list2code([1, "a", [2]]) catch ? "02 list2code: " + cCatchError done
try list2code(5) ? "03 list2code(5): no raise" catch ? "03 list2code(5): " + cCatchError done
try ? "04 randomlist: " + len(randomlist([1, 2, 3])) catch ? "04 randomlist: " + cCatchError done
try randomlist([]) ? "05 randomlist([]): no raise" catch ? "05 randomlist([]): " + cCatchError done
try ? "06 randomitem in list: " + (find([1, 2, 3], randomitem([1, 2, 3])) > 0) catch ? "06 randomitem: " + cCatchError done
try randomitem(5) ? "07 randomitem(5): no raise" catch ? "07 randomitem(5): " + cCatchError done
try ? "08 timeinfo: " + len(timeinfo(:date)) catch ? "08 timeinfo: " + cCatchError done
try ? "09 permutation: " + len(permutation([1, 2, 3])) catch ? "09 permutation: " + cCatchError done
try permutation([]) ? "10 permutation([]): no raise" catch ? "10 permutation([]): " + cCatchError done
try systemsilent("echo x") ? "11 systemsilent: ok" catch ? "11 systemsilent: " + cCatchError done
? "12 the bare names a program reads: " + C_LINESIZE + " " + C_ERROR_EMPTYLIST
? "13 list2code twice keeps its indent: " + len(list2code([[1]])) + " " + len(list2code([[1]]))
