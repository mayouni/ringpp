$g = [ [1,2], [3,4] ]

func M1()
    o = new G
    return o.Read()

func M2()
    o = new G
    return o.Sum()

func M3()
    o = new G
    return o.Write()

func M4()
    o = new G
    return o.Deep()

func M5()
    $g[1][2] = 42
    return $g[1][2]

func M6()
    # the aliasing case: a write through the attribute must be visible
    o = new G
    o.Write()
    return o.Read()

class G
    @a = [ [1,2], [3,4] ]
    @b = [ [5,6], [7,8] ]
    @c = [ [[1,2],[3,4]], [[5,6],[7,8]] ]

    def Read()
        return @a[1][2]

    def Sum()
        return @a[1][2] + @b[2][1]

    def Write()
        @a[1][2] = 9
        return @a[1][2]

    def Deep()
        @c[2][1][2] = 77
        return @c[2][1][2] + @c[1][1][1]
