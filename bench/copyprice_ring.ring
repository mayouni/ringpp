# The same rows on Ring itself (the oracle), so C-7's price is stated
# against what Ring pays for its own copy. Run FROM bench/ -- a root
# file's `load` resolves against the current directory (C-4):
#     cd bench && ..\runtime\win64\ring.exe copyprice_ring.ring
# NOT named *_run.ring on purpose: ab.py takes every such file as an A/B
# module, and this one runs Ring's 10.8-second AssignN five times -- it
# cost the gate 119 s on 2026-09-11 before it was renamed.
load "copyprice.ring"
TimeIt("SortN", 100000)
TimeIt("AssignN", 100000)
TimeIt("ParamN", 100)
func TimeIt cName, nArg
	nBest = 0
	nOut = 0
	for r = 1 to 5
		t = clock()
		nOut = call cName(nArg)
		d = (clock() - t) * 1000 / clockspersecond()
		if r = 1 or d < nBest nBest = d ok
	next
	? "RING  " + cName + " " + nBest + " ms  (result " + nOut + ")"
