# RING'S ANSWER for in_host.ring where it has one: eval(read()) stands in for
# admitfile() and eval() for admitcode(), as RingServ's host feeds Ring source.
load "in_host.ring"

func admitfile cFile
	eval(read(cFile))
	return 1

func admitcode cName, cSource
	eval(cSource)
	return 1
