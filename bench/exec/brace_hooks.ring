# Ring calls two hooks on an object brace. Its parser writes the guard out
# in a comment, src/expr.c:1021 and 1033:
#
#     if ismethod(self,"bracestart") bracestart() ok      on `{`
#     if ismethod(self,"braceend")   braceend()   ok      on `}`
#
# Ring++ fired neither until 2026-09-12. Softanza builds on BraceEnd:
# stzApp gathers `Graph = ...` into attributes inside the brace and folds
# them into its body when the brace closes. Without the hook the fold never
# ran, and app/02_stzapp_body failed 7 of its 12 assertions -- while printing
# MORE lines than Ring, because the narrated harness prints two extra
# `expected:/got:` lines per failure. 7 x 2 is exactly the 14 extra lines.
#
# Pinned here: both hooks, a brace on a plain object and on a method call,
# the nesting order, and a class with no hooks at all.
o = new T()
o {
	? "  inside the brace"
	X = 1
}
? "after: " + o.Trace()

? ""
p = new T()
p.Begin() {
	? "  inside a brace on a CALL"
}
? "after: " + p.Trace()

? ""
# nested: which order do the hooks fire in?
q = new T()
q {
	? "  outer body"
	Inner() {
		? "    inner body"
	}
}
? "after: " + q.Trace()

? ""
# a class with NO hooks must not break
n = new N()
n { ? "  no hooks here" }
? "plain object survived"

class T
	@t = ""

	def init()
		return This

	def BraceStart()
		@t += "[start]"

	def BraceEnd()
		@t += "[end]"

	def Begin()
		return This

	def Inner()
		return This

	def Trace()
		return @t

class N
	def init()
		return This
