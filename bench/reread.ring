# F-58: lines the grammar cuts or joins differently from Ring, A/B'd
# against the oracle (reread_run.ring).
#
# Inside a class, `return "" + @nRe + "-" + (-@nIm) + "i"` came back as
# `return ""` plus a second statement, `+ @nRe + ...`; and `x = "a"` on one
# line with `+ "b"` on the next came back joined, where Ring leaves x as
# "a". rereadSpan in src/compile.zig re-reads both the way Ring does. Every
# function here was a wrong answer or a refusal before it existed.

func RrContent(a, b)
	o = new RrC
	o.Set(a, b)
	return o.Content()

func RrSecs(a, b)
	o = new RrC
	o.Set(a, b)
	return o.Secs()

func RrTail(a, b)
	o = new RrC
	o.Set(a, b)
	return o.Tail()

func RrNoop()
	x = "a"
	+ "b"
	return x

func RrLead(n)
	s = n
	+ 2 * 3
	- 1
	return s

func RrTrail(n)
	s = n +
	    1 -
	    2
	return s

class RrC
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
	def Tail()
		return "" + @nRe + "-" + (-@nIm) + "i"
