func T1()
    o = new C
    return o.Val()

func T2()
    o = new C
    o.Bump()
    o.Bump()
    return o.Val()

func T3()
    o = new D
    return o.Val() + o.Extra()

class C
    @nVal = 10
    def Val()
        return This.@nVal
    def Bump()
        This.@nVal = This.@nVal + 1

class D from C
    @nMore = 5
    def Extra()
        return This.@nMore + @nVal
