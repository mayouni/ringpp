# RING'S ANSWER TO A SEQUENCE OF FILES run into one program: each file named
# after this one eval'd in order, as RingServ's host runs its library into one
# Ring state (ring_state_runcode). An error a file's top level does not catch
# is printed and the next file runs.
#     ring oracle_seq.ring a.ring b.ring ...
for nRppSeq = 3 to len(sysargv)
	try
		eval(read(sysargv[nRppSeq]))
	catch
		? "error: " + cCatchError
	done
next
