func A()
    n = 0
    try
        raise("x")
    catch
        n = 1
    finally
        n = n + 10
    done
    return n

func B()
    n = 0
    try
        n = 5
    catch
        n = 99
    finally
        n = n + 100
    done
    return n

func C()
    # catch(e) binds the caught value by name
    try
        raise("bound")
    catch(e)
        if e = "bound"
            return 1
        ok
        return 0
    done
    return -1

func D()
    # finally with no catch must run cleanup and let the error OUT
    n = 0
    try
        try
            raise("inner")
        finally
            n = 1
        done
    catch
        n = n + 10
    done
    return n
