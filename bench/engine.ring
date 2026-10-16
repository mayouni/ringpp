func E1()
    if LoadLib("rppdemo.dll") = 0
        return -1
    ok
    h = StzEngineString("hello")
    n = StzEngineStringLen(h)
    StzEngineStringFree(h)
    return n

func E2()
    LoadLib("rppdemo.dll")
    h = StzEngineString("ring plus plus")
    r = StzEngineStringToUpper(h)
    c = StzEngineStringData(r)
    StzEngineStringFree(r)
    StzEngineStringFree(h)
    return len(c) * 1000 + ascii(c[1])

func E3()
    LoadLib("rppdemo.dll")
    return StzEngineHypot(3, 4)

# ---- lists, ABI 2 (2026-09-10) ----------------------------------------
# A list can carry no meaning inside sixteen bytes, so these cross through
# the host callbacks. E4 reads one (nested), E5 builds one, E6 does both.

func E4()
	LoadLib("rppdemo.dll")
	return StzEngineListSum([1, 2, [3, 4, [5]], 6])

func E5()
	LoadLib("rppdemo.dll")
	a = StzEngineListMake(3)
	return "" + len(a) + " " + a[1] + " " + a[2] + " " + len(a[3]) + " " + a[3][2]

func E6()
	LoadLib("rppdemo.dll")
	a = StzEngineListUpper(["ring", "plus"])
	return "" + len(a) + " " + a[1] + " " + a[2]
