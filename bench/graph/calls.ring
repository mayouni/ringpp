func Top(x)
	return Helper(x)
func Helper(y)
	return y
class A
	def Foo()
		Bar()
		Top(1)
		len("abc")
	def Bar()
		return 1
class B from A
	def Baz()
		This.Foo()
		o = new A
		o.Bar()
		x.Unknown()
		y.Bar()
