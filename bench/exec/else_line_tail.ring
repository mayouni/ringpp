# F-110 and F-114 together: when the else body's last statement ends in a
# postfix construct -- here a call -- Ring has passed the newline behind it
# before that statement's own last instruction, so the else body does not end
# on a line marker, nothing merges with the next statement's, and the call
# after `ok` reports its OWN line even when the first branch ran. The first
# version of F-110 carried the `else` line here (linearsolver/13 and
# systemcall/03 in the wide suite).
x = 1
if x = 1
	? "the first branch"
else
	g()
ok

f()

func g
	return 1

func f
	raise("boom")
