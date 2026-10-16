# `obj { ... }`, every shape Ring 1.27 answers consistently (measured
# 2026-09-10 on both builds). The value is the object; inside the block a
# name is a local first, then the object's attribute; `@x` is the object's
# attribute; a bare call is the object's METHOD first, ahead of a global
# function of the same name; blocks nest and chain; a braced call result
# is the result. Softanza's app tests are written in this form.
#
# Left out on purpose, as decided divergences (C-6): assigning a name the
# object lacks creates a GLOBAL on Ring and raises R12 here; `self` inside
# a block at the top level is R13 on Ring; `This` there is UNKNOWN.
o = new K { x = 5 }
? "P1 attr set in braces: " + o.x
o { ? "P2 attr read in braces: " + x }
o { ? "P3 method call in braces: " + m() }
# P5 reads only z: `z = y { ... }` COPIES y on Ring and the block runs on
# the copy; objects alias here (C-7, pending), and y.x would show it.
y = new K
z = y { x = 1 }
? "P5 value of braces: " + type(z) + " x=" + z.x
? "P6 from a function: " + f()
? "P7 local vs attr: " + g()
o { p = new K { x = 42 }  ? "P8 nested: " + p.x  p { ? "P8 inner bare x: " + x } }
q = o.Q() { x = 9 }
? "P10 braced call result: " + q.x + " (o.x still " + o.x + ")"
o { ? "P11 bare call, method vs global func: " + m() }
? "P12 outside braces: " + m()
# Rule A spelling throughout: an attribute a METHOD writes is `@h` here
# (a bare `h = p` in a method is a local on Ring++, and `rnxc migrate`
# rewrites it); Ring reads `@h` as a plain identifier, so both agree.
s = new S { @v = 3  Has("t") }
? "P13 Softanza spelling: @v=" + s.@v + " has=" + s.@h
r = o { }
? "P15 empty braces: " + type(r)
? "P16 in a method: " + o.Build()
w = new K { x = 1 } { x = 2 }
? "P17 two brace blocks: " + w.x
o { x += 10 }
? "P18 compound on an attribute: " + o.x
# The two functions use names that are NOT top-level globals: on Ring a
# bare `o = ...` in a function would write the global o (the leak Rule A
# removes, C-2), and P10 would then read a different object on each side.
func f
	lf = new K { x = 1 }
	return lf.x
func g
	x = 100
	lg = new K { x = x + 1 }
	return "attr " + lg.x + " local " + x
func m
	return "GLOBAL m"
class K
	x = 0
	def m()
		return "METHOD m"
	def Q()
		return new K
	def Build()
		t = new K { x = 77 }
		return t.x
class S
	@v = 0
	@h = ""
	def Has(p)
		@h = p
