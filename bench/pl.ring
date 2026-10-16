func RangeLen()
    aR = 1:4
    return len(aR)

func RangeSum()
    aR = 3:7
    n = 0
    nL = len(aR)
    for i = 1 to nL
        n += aR[i]
    next
    return n

func LoopSkip()
    n = 0
    for i = 1 to 5
        if i = 3 loop ok
        n += i
    next
    return n

func WhileLoop()
    n = 0
    i = 0
    while i < 5
        i++
        if i = 2 loop ok
        n += i
    end
    return n
