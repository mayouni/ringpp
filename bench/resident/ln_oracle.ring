# RING'S ANSWER for ln_host.ring up to its replacement: eval(read()) stands
# in for admitfile(), eval() for admitcode() and replacecode(), as RingServ's
# host feeds Ring source. Ring refuses a class defined twice (C26), so the
# replacement has no answer here, nor does a release.
load "ln_host.ring"

func admitfile cFile
	eval(read(cFile))
	return 1

func admitcode cName, cSource
	eval(cSource)
	return 1

func replacecode cName, cSource
	eval(cSource)
	return 1

func releasecode cName
	return 1
