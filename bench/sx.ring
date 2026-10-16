func S1(n)
    r = 0
    switch n
    on 1
        r = 10
    on 2
        r = 20
        r = r + 2
    other
        r = 30
    off
    return r

func S2(n)
    c = "b"
    switch c
    on "a"
        return 1
    on "b"
        return 2
    off
    return 0

func S3(n)
    s = :beta
    switch s
    on :alpha
        return 11
    on :beta
        return 22
    off
    return 0

func P1()
    n = 5
    n++
    n++
    n--
    return n

func P2()
    # a comment inside a body used to poison the whole function
    n = 1
    n++
    return n
