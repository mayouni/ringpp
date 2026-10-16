for i = 1 to 2
	? "P1 " + i
next i
$x = 5
$x
? "P2 " + $x
$o = new K
? "P4 " + $o.N()
? "P6 " + $o.R()
class K
	@a = [1, 2, 3]
	@b = 0
	def N()
		del(@a, 1)
		return len(@a)
	def R()
		return @d@
	private
	@d@ = 7
	def Z()
		return @d@ + 1
