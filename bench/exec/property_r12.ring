# A PROPERTY THE CLASS DOES NOT HAVE is R12 at the READ, and Ring lets it
# be caught.
#
#     Error (R12) : Error in property name, property not found: x
#
# Catchable, the name folded to lower case, the program running on.
# Measured on 1.27 for all three shapes below -- and Ring++ REFUSED them at
# compile time, which is stricter than Ring and cost whole methods:
# `stzFile.PreserveAndModify` reads `This.cOriginalContent` where the
# attribute is declared `@cOriginalContent`, a one-line latent bug that
# compiled the method away rather than raising where Ring raises.
#
# It is the verdict `userCall` already carries for R19: a refusal is the
# safe answer only when the alternative is a WRONG one, and here the
# alternative is Ring's own answer.
#
# THE FIX WAS A DELETION. The by-NAME resolution an unproved receiver
# already uses (`gattrn`) raises exactly this error on a miss; the refusal
# stood in front of a path that was right all along.
#
# WHAT WAS LOST, and it is named rather than pretended away: the refusal
# used to say `This.Name is a METHOD, not a property -- write This.Name()`,
# which is always a real defect. That belongs to `rnxc check`, whose
# cross-file half waits on the definition universe.

? "-- 1. declared with the @ sigil, read without it --"
o = new A
try
	? "  This.x : " + o.R1()
catch
	? "  " + cCatchError
done

? ""
? "-- 2. a name that is a method of the class, read as a property --"
try
	? "  This.M : " + o.R2()
catch
	? "  " + cCatchError
done

? ""
? "-- 3. a name that is nothing at all --"
try
	? "  This.q : " + o.R3()
catch
	? "  " + cCatchError
done

? ""
? "-- 4. and a name the class DECLARES bare still reads (C-12) --"
? "  This.z : " + o.R4()

? ""
? "-- 5. the same three on ANOTHER object, not through This --"
try
	? "  o.nope : " + o.nope
catch
	? "  " + cCatchError
done

? ""
? "done"

class A
	@x = "AT-X"
	z = "BARE-Z"

	def M()
		return "I am a method"

	def R1()
		return This.x

	def R2()
		return This.M

	def R3()
		return This.q

	def R4()
		return This.z
