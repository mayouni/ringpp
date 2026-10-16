func O1()
    o = new K
    return o.Outer()

func O2()
    o = new K
    return o.WithArgs(5)

func O3()
    o = new L
    return o.Outer()

class K
    @nBase = 3

    def Inner()
        return @nBase * 10

    def Outer()
        # a bare call to the class's OWN method -- no This.
        return Inner() + 1

    def Twice(n)
        return n * 2

    def WithArgs(n)
        return Twice(n) + Inner()

class L from K
    def Inner()
        return 99
