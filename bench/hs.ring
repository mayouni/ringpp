func H1()
    aH = [ :a = 1, :b = 2 ]
    return len(aH)

func H2()
    aH = [ :a = 1, :b = 2 ]
    return aH[:b]

func H3()
    aH = [ :a = 1, :b = 2 ]
    aH[:a] = 9
    return aH[:a] + len(aH)

func H4()
    aH = [ :a = 1 ]
    aH[:c] = 30
    return aH[:c] + len(aH)

func H5()
    aH = [ :Name = 7 ]
    return aH["name"]

func H6()
    aN = [ :a = [ :b = 7 ] ]
    return aN[:a][:b]

func H7()
    aH = [ :a = 1, :b = 2 ]
    n = 0
    nL = len(aH)
    for i = 1 to nL
        n += aH[i][2]
    next
    return n

func H8()
    aH = [ :a = 1 ]
    aH[:a] = aH[:a] + 100
    return aH[:a]
