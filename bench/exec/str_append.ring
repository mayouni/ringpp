# Building a string a piece at a time used to be QUADRATIC here: every
# concatenation allocated a fresh buffer and copied both sides, so
# `s += "x"` 400,000 times copied about 80 GB -- 1.35 s against Ring's
# 0.02 s, measured 2026-09-13 from perf/engine_senses, which does exactly
# that. It grows in place now, for a local and for a global alike.
#
# THE DANGER IS ALIASING, and that is what this probe is for. Growing in
# place is only sound when nothing else can see the old value. Every case
# below shares a string and then appends to one of the names; if the
# sharing is ever missed, the other name changes too, silently.

s = "abc"
t = s
s += "d"
? "1 local alias    : s=" + s + " t=" + t

$g = "abc"
u = $g
$g += "d"
? "2 global alias   : g=" + $g + " u=" + u

aL = [ "abc" ]
v = aL[1]
v += "d"
? "3 out of a list  : v=" + v + " list=" + aL[1]

$h = "abc"
aM = [ $h ]
$h += "d"
? "4 global in list : g=" + $h + " list=" + aM[1]

o = new K()
o.Keep("abc")
w = o.Held()
w += "d"
? "5 attribute      : w=" + w + " held=" + o.Held()

x = "abc"
? "6 passed in      : " + grow(x) + " caller=" + x

# and the plain arithmetic the flag shares an opcode with
$n = 5
$n += 3
? "7 number global  : " + $n
m = 5
m += 3
? "8 number local   : " + m

# a compound append whose left side is a constant expression
$p = ""
for i = 1 to 3
	$p += "" + i
next
? "9 built in a loop: " + $p

func grow(p)
	p += "d"
	return p

class K
	@c = ""
	def init()
		return This
	def Keep(v)
		@c = v
	def Held()
		return @c
