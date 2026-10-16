# The parent of bench/exec/inherit_slots.ring, in its own file on purpose:
# the defect it pins is about the ORDER the files are read in.
#
# The line below is not decoration: every probe in this directory has a top
# level, so that it is a program in its own right and the image gate can
# prove a warm run of it.

? "the parent's file ran first"

class Parent
    cTag = "parent"
    aContent = []

    def ReadInParent()
        return aContent

    def FillFromParent(x)
        aContent = x

    def Tag()
        return cTag
