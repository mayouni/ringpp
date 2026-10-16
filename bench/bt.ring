func B1()
    return ceil(2.1) + floor(2.9) + sqrt(9)

func B2()
    return ceil(-2.1) + floor(-2.1)

func B3()
    return strcmp("a","a") + strcmp("a","b") + strcmp("b","a") + strcmp("abc","ab")

func B4()
    a = [10,20,30,40]
    del(a, 2)
    return len(a) * 100 + a[1] + a[2] + a[3]

func B5()
    return len( substr("hello world", 3) )

func B6()
    return len( substr("hello world", 3, 4) )

func B7()
    return substr("hello world", "wor")

func B8()
    return substr("hello", "zz")

func B9()
    return len( substr("hello", 20) )

func B10()
    c = substr("hello world", "o", "0")
    return len(c) + ascii(c[5])
