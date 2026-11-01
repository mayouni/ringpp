# RUNG 4: classes admitted later still, from a class admitted before them --
# its attributes and initial values inherited, `cKind` redeclared. One
# method each: on Ring a class an eval defines, from a class an earlier eval
# defined, loses its inherited init once it has two (F-148), and Ring's
# answer is read through eval (oracle_classes.ring).
func NewSquare n
	return new Square(n)

func NewCircle n
	return new Circle(n)

class Square from Shape
	cKind = "square"

	func Name
		return "sq" + nSide

class Circle from Shape

	# the one method call bound statically: a replaced Area must reach it
	func Area2
		return super.Area() + 1
