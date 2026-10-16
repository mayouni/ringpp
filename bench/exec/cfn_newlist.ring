# F-102. Ring registers `newlist` beside `list` (list_e.c) and names the one
# that was CALLED: `In newlist() In function f()`, where Ring++ said
# `In list()`.
f()

func f
	? len(newlist(2, 3))
	? newlist(0)
