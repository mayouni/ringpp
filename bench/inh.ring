? "=== 1. same-named attribute in parent and child"
o = new Child
? "  o.Show()       -> " + o.Show()
? "  o.ParentShow() -> " + o.ParentShow()
? "  o.@n from outside = " + o.@n
? "  how many slots?  " + len(attributes(o))
aA = attributes(o)
cL = ""
for a in aA cL += a + " " next
? "  attributes(o) = " + cL

? ""
? "=== 2. does the child's init run the parent's?"
o2 = new Child2
? "  o2.Val() = " + o2.Val() + "   (parent init sets 10, child sets 20)"

? ""
? "=== 3. what does the parent's method see?"
o3 = new Child3
? "  o3.FromParent() = " + o3.FromParent()
? "  -- does the parent method see the CHILD's override of @n?"

class Parent
    @n = 1
    def Show()
        return "parent sees @n=" + @n
    def ParentShow()
        return "parent method sees @n=" + @n

class Child from Parent
    @n = 2
    def Show()
        return "child sees @n=" + @n

class Parent2
    @v = 0
    def init()
        @v = 10
class Child2 from Parent2
    def init()
        @v = 20
    def Val()
        return @v

class Parent3
    @n = 100
    def FromParent()
        return @n
class Child3 from Parent3
    @n = 200
