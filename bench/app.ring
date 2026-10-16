func P1()
    a = [ [1], [2] ]
    a[1] + 9
    return len(a[1]) * 10 + a[1][2]

func P2()
    o = new H
    return o.Fill()

class H
    @rows = [ [1], [2] ]
    def Fill()
        @rows[2] + 7
        @rows[2] + 8
        return len(@rows[2]) * 100 + @rows[2][2] + @rows[2][3]
