# RING'S CLASS-REGION RULE (F-70), measured on 1.27: a name that nothing
# has assigned, READ in a class body, makes the object GAIN an attribute of
# that name holding NULL -- attributes(o) lists `$nope` -- and the value
# read is that NULL. The same read at the top level or in a function is
# R24; a method reading it finds the attribute. A global that IS set reads
# as itself. Softanza's stzDiagram reads `$cDefaultDiagramOutputFormat`
# in its class body, a name its tree never assigns (stzDotCode.ring
# defines `$cDefaultDotOutputFormat`), and three tests pass on the NULL.

$set = "svg"
o = new K
? "1 o.x: [" + o.x + "] type " + type(o.x)
? "2 o.y from a set global: [" + o.y + "]"
? "3 attributes: " + len(attributes(o))
# sorted: Ring lists the created attribute where the read happened (x,
# $nope, y); Ring++ lists it after the declared ones. Named, not matched.
for a in sort(attributes(o)) ? "   " + a next
try
	? "4 $nope at top level after: [" + $nope + "]"
catch
	? "4 " + cCatchError
done
try
	? "5 through a function: [" + G() + "]"
catch
	? "5 " + cCatchError
done
try
	? "6 a method reading it: [" + o.M() + "]"
catch
	? "6 " + cCatchError
done
p = new K
? "7 a second object: [" + p.x + "] attributes " + len(attributes(p))

func G
	return $nope

class K
	x = $nope
	y = $set
	def M
		return $nope
