# A METHOD CHAIN CONTINUED ON THE NEXT LINE: a line that ends in `.` is
# unfinished on Ring, so `o.A(1).` newline `A(2)` is one statement. The
# grammar cuts it into `o.A(1)` and a bare `A(2)`, which was R3 "a" -- the
# capstone's `oBrain.Know("margherita", "dish").` newline `Know(...)`
# stopped there. rereadSpan joins a dangling dot across rows now.

o = new K
o.A(1).
	A(2).
	A(3)
? "1 " + o.n
o.A(10).A(20).
  A(30)
? "2 " + o.n
x = o.A(1).
	A(1).n
? "3 " + x

class K
	n = 0
	def A(v)
		n += v
		return This
