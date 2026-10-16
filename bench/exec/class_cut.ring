$o = new C
$o.Set(3, -2)
? $o.Content()
? $o.Secs()
? $o.Noop()
$o.Set(1, 5)
? $o.Content()
? $o.Tail()

class C
	@nRe = 0
	@nIm = 0
	def Set(a, b)
		@nRe = a
		@nIm = b
	def Content()
		if @nIm < 0
			return "" + @nRe + "-" + (-@nIm) + "i"
		ok
		return "" + @nRe + "+" + @nIm + "i"
	def Secs()
		return (@nRe * 3600) + (@nIm * 60) + 7
	def Noop()
		x = "a"
		+ "b"
		return x
	def Tail()
		return "" + @nRe + "-" + (-@nIm) + "i"
