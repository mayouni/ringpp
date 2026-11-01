# RING'S ANSWER for am_host.ring up to the class replacement: eval() stands in
# for admitcode() and replacecode(), as RingServ's host feeds Ring source.
# Ring refuses a class defined twice (C26), so the replacement has no answer.
load "am_host.ring"

func admitcode cName, cSource
	eval(cSource)
	return 1

func replacecode cName, cSource
	eval(cSource)
	return 1
