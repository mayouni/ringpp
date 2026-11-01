# Defines what r02 called: from now on that call reaches it.
? "r03: " + CallsLater(10)
? "r03: " + isFunction("later")
try
	? CallsLater2()
catch
	? "r03: " + cCatchError
done

func Later n
	return n * 100

func Later2 a
	return a
