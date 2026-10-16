# Object model: attributes, methods, This, new, inheritance, member calls.

func UseCounter nN
    oC = new Counter(100)
    for i = 1 to nN
        oC.Bump(i)
    next
    return oC.Value()

func UseSeen nN
    oC = new Counter(0)
    for i = 1 to nN
        oC.Bump(i)
    next
    return oC.Seen()

func UseInherit nN
    oD = new Doubler(100)
    for i = 1 to nN
        oD.Bump(i)
    next
    return oD.Value()

func UseInheritSeen nN
    oD = new Doubler(0)
    for i = 1 to nN
        oD.Bump(i)
    next
    return oD.Seen()

class Counter
    @nVal
    @aSeen = []

    def init(pStart)
        @nVal = pStart
        @aSeen = []

    def Value()
        return @nVal

    def Bump(pN)
        @nVal = @nVal + pN
        add(@aSeen, pN)
        return This.Value()

    def Seen()
        return len(@aSeen)

class Doubler from Counter

    def Bump(pN)
        @nVal = @nVal + pN + pN
        add(@aSeen, pN)
        return This.Value()
