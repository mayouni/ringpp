# F-90. A `return`, `exit` or `loop` that leaves a `try` body leaves its
# handler too. Ring++ left it on the handler stack -- `ret` never touched
# it and only a try body that FELL THROUGH emitted `pend` -- so an error
# raised later unwound into the catch of a frame that had already
# returned, and 256 returns from a try overflowed the stack (a panic).
# Found through Softanza: @IsStzObject is `try return p.IsStzObject()
# catch return 0 done`, and the R24 stzList.operator raises next was
# caught by THAT dead handler, which returned 0 into the operator.
#
# Measured on both 1.27 builds. Ring cuts its try list back at a METHOD's
# return, at `exit` and at `loop`; at a plain FUNCTION's return it does
# not, and a raise() after one kills Ring with no message at all (exit 1)
# -- that row is not pinned here, see C-21. A runtime error after one is
# caught where it should be on Ring too (row 2).

? "2 caller catches : " + Row2()
n = 0
for i = 1 to 1000
	n += Guarded(i)
next
? "3 a thousand     : " + n
? "4 exit           : " + Row4()
? "5 loop           : " + Row5()
? "6 nested         : " + Row6()
o = new K
? "7 method, caught : " + o.Row1()
m = 0
for i = 1 to 1000
	m += o.Guarded(i)
next
? "8 a thousand, m  : " + m
? "9 exit 2         : " + Row9()
? "done"

func Guarded(x)
	try
		return 1
	catch
		return 0
	done

func Row2()
	try
		v = Guarded(1)
		w = v + []
	catch
		return "row 2 handler, " + cCatchError
	done

func Row4()
	try
		for i = 1 to 3
			try
				if i = 2  exit  ok
			catch
				return "the inner (dead) handler"
			done
		next
		raise("after the loop")
	catch
		return "row 4 handler, " + cCatchError
	done

func Row5()
	try
		for i = 1 to 3
			try
				if i < 3  loop  ok
			catch
				return "the inner (dead) handler"
			done
		next
		raise("after the loop")
	catch
		return "row 5 handler, " + cCatchError
	done

func Row6()
	try
		try
			raise("inner")
		catch
			return Inner6()
		done
	catch
		return "the outer handler"
	done

func Inner6()
	try
		raise("in Inner6")
	catch
		return "Inner6's own handler"
	done

func Row9()
	try
		for i = 1 to 2
			try
				for j = 1 to 2
					try
						if j = 2  exit 2  ok
					catch
						return "a dead inner handler"
					done
				next
			catch
				return "a dead middle handler"
			done
		next
		raise("after both loops")
	catch
		return "row 9 handler, " + cCatchError
	done

class K
	def Guarded(x)
		try
			return 1
		catch
			return 0
		done

	def Row1()
		try
			This.Guarded(1)
			raise("after the call")
		catch
			return "row 7 handler, " + cCatchError
		done
