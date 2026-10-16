# F-110, the two ways a carried line could go wrong. A branch's if nested in
# another branch skips the enclosing branch's line marker too, and keeps its
# own line (Ring's jump lands on the enclosing jump, past the marker the two
# share). And a later turn through the ELSE runs the merged marker, so what
# an earlier turn's jump carried is gone: the second turn reports the
# statement's own line.
for i = 1 to 2
	if i = 1
		if i = 1
			? "turn 1: inner first branch"
		else
			? "turn 1: inner else"
		ok
	else
		? "turn 2: the else"
	ok
	g(i)
next

func g n
	if n = 2 raise("boom on turn " + n) ok
