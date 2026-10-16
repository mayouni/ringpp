func C1()
    f = func(x) { return x * 2 }
    return call f(21)

func C2()
    n = 40
    f = func(x) { return x + n }
    return call f(2)

func C3()
    return Apply(func(x) { return x * 10 }, 4)

func Apply(fn, v)
    return call fn(v)

func C4()
    # the case Ring cannot do: the environment must survive the return
    h = MakeAdder(10)
    return call h(5)

func MakeAdder(k)
    return func(x) { return x + k }

func C5()
    a = 1
    b = 2
    f = func() { return a + b }
    return call f()
