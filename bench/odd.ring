# Four shapes from the `identifier` refusals of 2026-09-08, each probed on
# the oracle first (odd_run.ring A/Bs them):
#   `next i`      is `next` and then a read of i -- fine when i exists,
#                 R24 when it does not (`next zzz`)
#   a bare name   on its own line is a read Ring performs and discards
#   del(@attr, n) mutates the attribute in place (len 3 -> 2)
#   `private`     after methods hands the class its attribute context back:
#                 `@d@ = 7` written there is a real attribute, and the
#                 methods after it are real (private) methods

func OddNext()
	s = 0
	for i = 1 to 3
		s = s + i
	next i
	return s

func OddBare()
	x = 5
	x
	return x

func OddDel()
	o = new OddK
	return o.N()

func OddPrivate()
	o = new OddK
	return o.Y()

func OddPrivateMethod()
	o = new OddK
	return o.YZ()

# `call pf()` inside a loop body arrives wrapped in an expression statement
# and reached the generic refusal (45 Softanza sites). No capture here, so
# Ring agrees: the lambda reads nothing from its maker.
func OddCallKw()
	f = func { return 7 }
	o = new OddK
	return o.RunTimes(3, f)

class OddK
	@a = [1, 2, 3]
	def N()
		del(@a, 1)
		return len(@a) * 10 + @a[1]
	def Y()
		return @d@
	def YZ()
		return This.Z()
	def RunTimes(k, pf)
		s = 0
		for i = 1 to k
			s = s + call pf()
		next
		return s
	private
	@d@ = 7
	def Z()
		return @d@ + 1
