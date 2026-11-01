# RING'S OWN ANSWER for the files `rnxc resident` admits in bench/resident.py's
# sequence: each file's text eval'd in order into one running program, the way
# RingServ's host runs its library files into one Ring state. The refused files
# are left out -- Ring would accept them, and that difference is the point.
aFiles = ["r01_base.ring", "r02_forward.ring", "r03_later.ring", "r05_after.ring", "r09_error.ring", "r10_eval.ring"]
for cFile in aFiles
	try
		eval(read(cFile))
	catch
		? "error: " + cCatchError
	done
next
