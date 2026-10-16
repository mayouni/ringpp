# A child class gets its parent's attributes FIRST, whatever order the
# files were read in -- and a redeclared one is the SAME property.
#
# Both halves measured on Ring 1.27, and both were wrong here.
#
# ORDER. A class may name a parent that has not been read yet. Softanza
# loads number/stzListOfNumbers.ring at line 58 of stzBase and the stzList
# it inherits from at line 253, so the child was laid out with no parent at
# all: its own twelve attributes and none of stzList's eighty-four. The
# inherited method `_EngineListFromContent` then read `@aContent` at slot 39
# of an object with twelve slots, and FIVE tests in the wide clock died on
# that one line. Classes are linked and laid out after every file is read
# now, parents first.
#
# REDECLARATION. `class stzListOfNumbers from stzList` names `@aContent`
# again, which stzList already has. Ring gives that ONE property -- probed:
# `attributes()` lists it once, and the parent's methods and the child's
# read and write the same storage. Ring++ gave it two slots.
#
# The parent here is in ANOTHER FILE, loaded BEFORE the child is declared,
# which is the arrangement that failed.

load "inherit_slots_parent.ring"

? "-- the child's own view --"
o = new Child
? "attributes: " + len(attributes(o))
o.FillFromChild([1, 2, 3])
? "the child reads  : " + len(o.ReadInChild())
? "the PARENT reads : " + len(o.ReadInParent())

? ""
? "-- and one property, written from either side --"
o.FillFromParent([9, 9])
? "after the parent wrote, the child reads: " + len(o.ReadInChild())
? "and the parent's own name is there too : " + o.Tag()

? ""
? "-- a child that does NOT redeclare still inherits every slot --"
p = new Plain
? "attributes: " + len(attributes(p))
p.FillFromChild([4, 5, 6, 7])
? "the PARENT reads : " + len(p.ReadInParent())

? ""
? "-- and the attribute NAMES, in order, merged --"
cR = ""
aA = attributes(o)
for i = 1 to len(aA)  cR += aA[i] + " "  next
? "  " + cR

class Child from Parent
    aContent

    def FillFromChild(x)
        aContent = x

    def ReadInChild()
        return aContent

class Plain from Parent
    somethingElse

    def FillFromChild(x)
        aContent = x
