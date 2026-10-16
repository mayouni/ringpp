$s = ""
for j = 5 to 1 step -1
	$s += "" + j
next
? "F1 " + $s
$t = ""
for k = 1 to 5 step 2
	$t += "" + k
next
? "F2 " + $t
$u = 0
for m = 3 to 1 step -1
	if m = 2
		$u = m
		exit
	ok
next
? "F3 " + $u
? "F4 " + F()
func F()
	r = ""
	for j = 4 to 1 step -1
		r += "" + j
	next
	return r
