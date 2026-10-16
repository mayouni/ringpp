# F-110: the first statement after `if ... else ... ok`, reached from a
# branch that is not the last, reports the line of the `but`/`else` that
# ended that branch. Ring's line is the last NEWLINE instruction it ran, a
# newline after another is merged into it, so that statement's marker IS the
# else body's last one -- and every earlier branch's end-jump lands past it.
# Here both frames of the trace show it: g's call of f, reached from the
# `but` branch, and the top level's call of g, reached from the first branch.
x = 1
if x = 1
	? "top: the first branch"
else
	? "top: the else"
ok
g(2)

func g n
	if n = 1
		? "g: the first branch"
	but n = 2
		? "g: the but"
	else
		? "g: the else"
	ok
	f()

func f
	raise("boom")
