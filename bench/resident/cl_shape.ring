# RUNG 4: classes admitted after the first file. cl_host.ring admits this,
# then a class inheriting from it (cl_square.ring), then replaces it while
# its objects exist -- and while one of its methods runs.
? "shape: its top level runs"

func NewShape n
	return new Shape(n)

func NewTag
	return new Tag

func NewEmpty
	return new Empty

func Describe o
	return o.Name() + " " + o.Area()

class Shape
	nSide = 0
	cKind = "shape"

	func init n
		nSide = n

	func Area
		return nSide * nSide

	func Name
		return cKind + "(" + nSide + ")"

	# a static call: This is proved, so it is bound to Area where it stands
	func Twice
		return This.Area() * 2

	# replaced while it runs: its frame finishes the old body
	func Grow
		for i = 1 to 2
			? "grow old " + i
			if i = 1
				replacecode("grow2", "class Shape" + nl + tab + "nSide = 0" + nl + tab + "cKind = 'SHAPE'" + nl + "func Grow" + nl + tab + "return 'grow new'" + nl)
			ok
		next
		return "grow old finished"

# no init: a replacement may not add one
class Tag
	cName = "tag"

	func Show
		return cName

# no attributes and no class-region code: nothing runs at `new`
class Empty

	func Hi
		return "hi"
