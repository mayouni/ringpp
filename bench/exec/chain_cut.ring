# The grammar cuts a call chain at a `.` the way F-58's cut lands on a `+`.
#
# `return This.BQ().Name()` came back from the parser as THREE statements --
# a bare `return`, `This.BQ()` carrying a dangling `.`, and `Name()` alone,
# the last two having fallen OUT of the function into the class body. Ring++
# compiled that as written: it returned the INTERMEDIATE OBJECT and called
# Name() on This in code no one could reach. Silent -- nothing was refused.
#
# The trigger is a comment line before the def: without one the same text
# parses whole. So the comments below are LOAD-BEARING. Do not tidy them.
#
# Found 2026-09-12 from stzStopwatch.TraceId(), which returned an object
# where Ring returns a string, and took perf/stopwatch out of the 34.

o = new A()

? "one-liner  : " + o.Chain()
? "two-step   : " + o.TwoStep()
? "same name  : " + o.Name()
? "three deep : " + o.Deep()

class A
	@oB = ""

	def init()
		return This

	def BQ()
		if @oB = ""
			@oB = new B()
		ok
		return @oB

	# a comment before the def -- this is what shifts the parse
	def Chain()
		return This.BQ().Name()

	# the two-step form always worked; it is the control
	def TwoStep()
		x = This.BQ()
		return x.Name()

	# the called method sharing this method's name is not the trigger,
	# but it is the shape the estate actually had
	def Name()
		return This.BQ().Name()

	# three links, so a span that swallows only one tail still fails
	def Deep()
		return This.BQ().Itself().Name()

class B
	def init()
		return This

	def Itself()
		return This

	def Name()
		return "the-string"
