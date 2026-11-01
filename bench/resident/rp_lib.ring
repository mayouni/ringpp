# RUNG 3: the library rp_host.ring admits and then replaces parts of. Every
# call between these functions is a static call, compiled before any
# replacement existed: the replacements must reach them where they stand.
? "lib: its top level runs"

func Price n
	return n * 10

func Report n
	return "report " + Price(n)

# answers an integer; its replacement answers a string
func Kind
	return 7

func Describe
	k = Kind()
	t = "tmp " + Kind()
	k2 = k
	return "kind " + k + " " + k2 + " " + len(t)

# replaced while it runs: its frame finishes the old body
func Loop
	for i = 1 to 3
		? "loop old " + i
		if i = 2
			replacecode("loop2", "func Loop" + nl + tab + "return 'loop new'" + nl)
		ok
	next
	return "loop old finished"

# replaced in the middle of its own recursion: the frames in the old body
# finish it, and the call it makes next reaches the new one
func Countdown n
	? "countdown old " + n
	if n = 2
		replacecode("countdown2", "func Countdown n" + nl + tab + "? 'countdown new ' + n" + nl + tab + "if n > 0" + nl + tab + tab + "Countdown(n - 1)" + nl + tab + "ok" + nl)
	ok
	if n > 0
		Countdown(n - 1)
	ok
