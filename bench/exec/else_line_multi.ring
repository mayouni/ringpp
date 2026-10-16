# F-110: only the statement's FIRST line reports the carried line. Ring runs
# a line marker at every newline it passes, inside a statement too, so a call
# on the statement's second line reports that line, as it would anywhere.
x = 1
if x = 1
	? "the first branch"
else
	? "the else"
ok
y = 1 +
	2 + f()

func f
	raise("boom")
