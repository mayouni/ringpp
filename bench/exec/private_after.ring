# TWO CLASSES, EACH ENDING IN A `private` SECTION -- Ring's own ziplib.ring
# is this shape (class zip, then class ZipEntry, each declaring its handle
# after `private`).
#
# The grammar reads `private` as opening a section that runs to the END OF
# THE FILE, so the second class -- and the `private` that follows it -- are
# parsed as children of the FIRST class's section, siblings of each other.
# The attribute walk follows the tree, so the second class's `oX` was never
# its attribute: every method's read of it was a Rule A refusal, and its
# declaration, fed to the right prologue by the positional pass (which
# follows the FILE, as Ring does), refused itself the moment a bare
# declaration became a statement.
#
# The name is registered where the statement is fed now, so the prologue
# and the attribute list cannot disagree whatever the tree says. Probed on
# 1.27: both classes work, and Ring prints `f` then `7`.

o = new First
o.Store("f")
? o.Fetch()
e = new Second(7)
? e.Read()
? "declared, never assigned, read through the class that owns it: <" + e.Blank() + ">"
? "done"

class First
	func Store c
		cName = c
	func Fetch
		return cName
	private
		cName = ""
		oX

class Second
	func init p
		oX = p
	func Read
		return oX
	func Blank
		return cSpare
	private
		oX
		cSpare
