# RING'S ANSWER for cl_host.ring up to its first replacement: eval(read())
# stands in for admitfile(), eval() for admitcode() and replacecode(), as
# RingServ's host feeds Ring source. Ring refuses a class defined twice (C26),
# so a replacement has no answer here.
load "cl_host.ring"

func admitfile cFile
	eval(read(cFile))
	return 1

func admitcode cName, cSource
	eval(cSource)
	return 1

func replacecode cName, cSource
	eval(cSource)
	return 1
