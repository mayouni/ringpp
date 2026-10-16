# A class attribute DECLARED without `@` is read and written by its bare
# name inside the class's methods -- Ring resolves a bare name local ->
# attribute -> global, and this is step two (measured 2026-09-11 on both
# builds). Step one was implemented and step two was not, so the read was
# refused (196 sites in Softanza) and the WRITE silently became a local:
# Ring stored xyz in the attribute, Ring++ left it at "start", with no
# error. A local of that name still wins -- a parameter SHIELDS an
# attribute on Ring, and an earlier assignment makes one.
o = new K
? "A read a declared attr, bare:  " + o.Fetch()
o.Store("xyz")
? "B after a bare WRITE in a method: " + o.Fetch() + " / direct: " + o.cTP
o.StoreQ("abc")
? "C after This.cTP write:          " + o.Fetch()
o.Bump()
? "D compound += on a bare attr:    " + o.Nb()
? "E a parameter shields it:        " + o.Shadow("param") + " / attr still " + o.Fetch()
p = new Child
? "F inherited attribute, bare:     " + p.Fetch() + " / child method: " + p.Deep()
class K
	cTP = "start"
	nb = 1
	def Fetch()
		return cTP
	def Store(v)
		cTP = v
	def StoreQ(v)
		This.cTP = v
	def Bump()
		nb += 4
	def Nb()
		return nb
	def Shadow(cTP)
		return cTP
class Child from K
	def Deep()
		return cTP + "!"
