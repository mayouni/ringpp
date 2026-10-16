func U1()
    o = new D
    return o.Val()

func U2()
    o = new D
    return o.Twice(4)

func U3()
    "a bare literal statement, legal Ring, does nothing"
    42
    return 1

class C
    @n = 10
    def Val()
        return @n
    def Twice(x)
        return x * 2

class D from C
    def Val()
        return super.Val() + 5
    def Twice(x)
        return super.Twice(x) + 100
