# `o.attr` where o's class is NOT provable at the site -- a parameter, a
# global, an attribute holding an object -- resolved by name at run time
# from the object's actual class (gattrn / sattrn), as Ring does at every
# property access. 105 sites in Softanza on 2026-09-09, all of the shape
# `@oDiagram = poDiagram` then `@oDiagram.@cTheme`. Each function here was
# a refusal or a wrong answer before; member_run.ring A/Bs them.

func MbProved()
	o = new MbB
	return o.@ax

func MbParam()
	o = new MbD
	return MbFetchY(o)

func MbParamInherited()
	o = new MbD
	return MbFetchX(o)

func MbBareInit()
	o = new MbB
	return o.x

func MbWrite()
	o = new MbB
	MbPut(o, 5)
	return o.x

func MbMissing()
	o = new MbB
	try
		return o.nope
	catch
		return cCatchError
	done

func MbHeld()
	h = new MbHolder
	h.Adopt(new MbD)
	return h.Theme()

func MbFetchY(q)
	return q.y

func MbFetchX(q)
	return q.x

func MbPut(q, v)
	q.x = v

class MbB
	x = 1
	@ax = 3

class MbD from MbB
	y = 2

class MbHolder
	@o = ""
	def Adopt(po)
		@o = po
	def Theme()
		return @o.y * 10 + @o.x
