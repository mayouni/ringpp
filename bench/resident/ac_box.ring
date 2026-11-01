# admitted second: the attribute `color` is a name new to the program, and
# its getter and setter are names it already holds
func MakeBox
	return new Box

func BoxColour b
	return b.color

func PaintBox b, c
	b.color = c

class Box
	color = "raw"
	def getColor
		return "got " + color
	def setColor c
		color = c + " (set)"
