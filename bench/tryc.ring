func E1()
    n = 0
    try
        n = 1
        raise("boom")
        n = 99
    catch
        n = n + 10
    done
    return n

func E2()
    try
        Deep()
        return 0
    catch
        return 7
    done

func Deep()
    Deeper()

func Deeper()
    raise("from three frames down")

func E3()
    # the defect §2.17 calls the serious one: a callee must NOT be able
    # to overwrite the error its caller is handling
    try
        raise("mine")
    catch
        Helper()
        if cCatchError = "mine"
            return 1
        ok
        return 0
    done

func Helper()
    try
        raise("theirs")
    catch
    done

func E4()
    # nested handlers keep separate bindings
    try
        raise("outer")
    catch
        try
            raise("inner")
        catch
        done
        if cCatchError = "outer"
            return 1
        ok
        return 0
    done

func E5()
    n = 0
    try
        n = 5
    catch
        n = 99
    done
    return n
