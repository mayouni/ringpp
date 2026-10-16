# THE PARENTHESES DECIDE WHETHER `init` RUNS. Measured on 1.27,
# 2026-09-10: `new K` leaves a class with `def init(x)` at its declared
# values -- init is not called, whatever its arity -- while `new M()`
# calls a zero-parameter init and `new K(9)` passes its argument.
# Ring++ called init either way, so `$a = new K` raised R24 on the first
# line of a program that runs on Ring. And `new C(args)` is a second
# grammar node (new_with_parens) that was never routed to the object
# path at all -- 17 roots in Softanza.
$a = new K
? "P1 " + $a.Seen()
$d = new M
? "P4 " + $d.Seen()
$e = new M()
? "P5 " + $e.Seen()
$f = new K(9)
? "P6 " + $f.Seen()
class K
	@seen = "no-init"
	def init(x)
		@seen = "init:" + x
	def Seen()
		return @seen
class M
	@seen = "no-init"
	def init()
		@seen = "init0"
	def Seen()
		return @seen
