func M(n)
    switch n
    on 1, 2, 3
        return 100
    on 7
        return 200
    other
        return 300
    off
    return 0

func Loop1()
    for i = 1 to 5
    next
    return i
