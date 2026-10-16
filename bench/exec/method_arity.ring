# A METHOD called with the wrong number of arguments. Ring counts at the
# call: R19 for too few, R20 for too many, both catchable, and the method
# is never entered -- no "entered" line below prints for a bad call, on
# either 1.27 build. Ring++ checked a FUNCTION's count and never a
# method's: it entered them all, with a parameter missing or an argument
# dropped. Softanza's stzString.FromHex() calls a helper's FromHex(cHex)
# with no argument, which is how this was found (2026-09-30).
o = new K
try  o.M()        catch  ? "few, proved      : " + cCatchError  done
try  o.M(1, 2)    catch  ? "many, proved     : " + cCatchError  done
p = MakeK()
try  p.M()        catch  ? "few, by name     : " + cCatchError  done
try  p.M(1, 2)    catch  ? "many, by name    : " + cCatchError  done
? "right count      : " + o.M(5)
try  q = new K2(1, 2)   catch  ? "init many        : " + cCatchError  done
try  q = new K2()       catch  ? "init few         : " + cCatchError  done
q = new K2(7)
? "init right       : " + q.v
c = new C
try  c.Few()   catch  ? "super few        : " + cCatchError  done
try  c.Many()  catch  ? "super many       : " + cCatchError  done
b = new B
try  b { x = 1 }  catch  ? "brace hook       : " + cCatchError  done
? "done"

func MakeK
	return new K

class K
	def M(a)
		? "entered M"
		return a

class K2
	v = 0
	def init(a)
		? "entered init"
		v = a

class P
	def M(a)
		? "entered P.M"
		return a

class C from P
	def Few()
		return super.M()
	def Many()
		return super.M(1, 2)

class B
	x = 0
	def BraceEnd(z)
		? "entered BraceEnd"
