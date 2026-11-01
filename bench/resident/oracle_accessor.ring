# RING'S ANSWER for ac_host.ring: eval(read()) stands in for admitfile(), as
# RingServ's host feeds Ring source.
load "ac_host.ring"

func admitfile cFile
	eval(read(cFile))
	return 1
