# An integer stored over a temporary that held a list released nothing,
# so the list kept a count nobody held -- one more for every call.
# `n = len($aL)` then `y = [10]`: the second statement's `loadi` landed on
# the register the first had read $aL into. A list built fresh and dropped
# that way was never freed (`n = len(Make())`, about 170 bytes a call: 70 MB
# for 200,000 calls where Ring stays at 18), and a global's phantom holders
# made Ring's count of a `ref()` wrong (F-118). refcount() is Ring's count of
# the named holders, so each row reads 1 on Ring; the build before read 1,002
# after row 2 and climbed.
#
# Row 4: a call site inside `?` is a call site. The classifier observed only
# expression statements and returns, so H's parameter was typed from
# `H(5)` alone and the list `? H(aL)` handed it sat in a register no sweep
# releases.

$aL = [1, 2, 3]
? "1 start " + refcount($aL)
for i = 1 to 1000
	G()
next
? "2 after 1000 G() " + refcount($aL)
for i = 1 to 1000
	K()
next
? "3 after 1000 K() " + refcount($aL)
H(5)
for i = 1 to 3
	? "4 H(list) inside ? " + H([7, 8, 9])
next
? "5 after H " + refcount($aL)

func G
	n = len($aL)
	y = [10]

func K
	x = $aL[2] + 1
	z = [x]

func H p
	if isList(p) return len(p) ok
	return p
