func R1()
    o = new CA
    return o.Val()

func R2()
    o = new CB
    return o.Val()

func R3(n)
    # two different classes on two branches -- inference must NOT prove one
    if n = 1
        o = new CA
    else
        o = new CB
    ok
    return o.Val()

func R4()
    # a subclass inheriting the method
    o = new CD
    return o.Val() + o.Extra()

func R5()
    # reassigned to another class after first use
    o = new CA
    a = o.Val()
    o = new CB
    return a + o.Val()

func R6()
    # receiver from a function return -- unprovable, must stay dynamic
    o = MakeB()
    return o.Val()

func MakeB()
    return new CB

class CA
    def Val()
        return 10

class CB
    def Val()
        return 20

class CC
    nBase = 5
    def Val()
        return 100

class CD from CC
    def Extra()
        return 7
