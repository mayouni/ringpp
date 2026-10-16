# A character range's strings are the VM's pinned one-character strings,
# and the range pushed them into its list WITHOUT a retain. Every freed
# list then released each one once more than it held, the pin drained,
# and the cache handed out freed memory: reassigning an object whose
# attribute held "A":"L" printed garbage and the process spun at exit.
# Pre-existing since 2026-09-10; exposed by F-91's early store, which
# releases the old object before the new one's arguments are built.

o = new P("A":"L")
? "1 " + o.Item()
o = new P("A":"L")
? "2 " + o.Item()
o = ""
o = new P("A":"L")
o.Parse(3, 9, 3)
? "3 " + o.Item()
? "4 " + T()
for i = 1 to 50
	aL = "a":"z"
	aL = ""
next
? "5 " + Join("a":"e")
? "done"

func T
	q = new P("A":"E")
	q = new P("A":"E")
	q.Parse(2, 4, 1)
	return q.Item()

func Join(aL)
	s = ""
	for x in aL  s += x  next
	return s

class P
	@aList = []
	@n = 1
	def init(pa)
		@aList = pa
		This.Parse(1, len(pa), 1)
	def Parse(a, b, c)
		@n = a
	def Item()
		return @aList[@n]
