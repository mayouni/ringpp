# The same report from inside a method: `In method m() in file F`.
o = new K
o.M(3)
class K
	def M(n)
		y = [1, 2]
		return y[n]
