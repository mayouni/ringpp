func N1()
    a = [ [1,2], [3,4] ]
    return a[1][2]

func N2()
    a = [ [1,2], [3,4] ]
    return a[1][2] + a[2][1]

func N3()
    a = [ [1,2], [3,4] ]
    a[1][2] = 9
    return a[1][2]

func N4()
    a = [ [1,2], [3,4] ]
    a[2][1]--
    return a[2][1]

func N5()
    a = [ [1,2], [3,4] ]
    r = a[1]
    return r[2]
