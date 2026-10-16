# How Ring's object orientation actually behaves. Three facts that
# compound, and together explain why parent/child attribute access is
# confusing -- the confusion is earned, not a misreading.
#
#     ring oo_facts.ring

? "=== 1. a child re-declaring a parent's attribute SHARES ONE SLOT"
o = new Child
? "  child method  : " + o.Show()
? "  PARENT method : " + o.ParentShow() + "   <-- sees the CHILD's value"
aA = attributes(o)
cL = "" for a in aA cL += a + " " next
? "  attributes(o) : " + cL + "  (one slot, not two)"
? "  so a parent cannot hold state a child is unable to overwrite"

? ""
? "=== 2. `new X` does NOT run init; `new X()` does"
a = new A
b = new A()
? "  new A   -> @v = " + a.Val() + "   <-- init SKIPPED, no error"
? "  new A() -> @v = " + b.Val()
? "  a missing pair of parentheses decides whether the object is built"

? ""
? "=== 3. a child's init does NOT call its parent's"
e = new E()
? "  new E() -> parent @p = " + e.P() + "   child @c = " + e.C()
? "  chaining is manual; forget it and the parent's invariant is absent"

class Parent
    @n = 1
    def Show()        return "@n=" + @n
    def ParentShow()  return "@n=" + @n
class Child from Parent
    @n = 2
    def Show()        return "@n=" + @n

class A
    @v = 0
    def init()  @v = 10
    def Val()   return @v

class P
    @p = 0
    def init()  @p = 7
class E from P
    @c = 0
    def init()  @c = 9
    def P()     return @p
    def C()     return @c
