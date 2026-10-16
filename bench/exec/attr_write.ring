# C-12 on the WRITE paths: a class attribute declared WITHOUT `@`.
#
# Reading one bare has worked since C-12. Writing one bare did not: the
# append `aCalls + [...]`, the indexed write `aGrid[1][2] = v` and the
# indexed append all ended at "bare name is not a local (Rule A)", so a
# class written in this style compiled its reads and refused the methods
# that build it. Measured on Softanza's governed_loop unit, 2026-09-12:
# 87 refusals of that one message, the largest class in the unit.
#
# Ring's own resolution is local -> attribute -> global, which is what
# makes the bare spelling legal in the first place.

o = new Recorder()

o.ScaleUp("web")
o.ScaleDown("db")
o.Tag(3, "third")
o.Deep()

? "calls     : " + o.CallCount()
? "first     : " + o.First()
? "tags[3]   : " + o.TagAt(3)
? "deep[2][1]: " + o.DeepAt()
? "appended  : " + o.LastTag()

class Recorder
	aCalls = []
	aTags = ["a", "b", "c"]
	aGrid = [[1, 2], [3, 4]]

	def init()
		return This

	# the plain append, bare
	def ScaleUp(pcTag)
		aCalls + [ "scaleup", pcTag ]

	def ScaleDown(pcTag)
		aCalls + [ "scaledown", pcTag ]

	# the indexed write, bare
	def Tag(n, pcVal)
		aTags[n] = pcVal

	# the indexed write one level down, bare
	def Deep()
		aGrid[2][1] = 99
		aTags + "appended"

	def CallCount()
		return len(aCalls)

	def First()
		return aCalls[1][1]

	def TagAt(n)
		return aTags[n]

	def DeepAt()
		return aGrid[2][1]

	def LastTag()
		return aTags[len(aTags)]
