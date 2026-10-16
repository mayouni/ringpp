// Where this VM used to @panic, Ring raises something a program can
// CATCH -- and Softanza catches these and shows them to people. Every
// message here was measured on 1.27 first.
//
// Each case returns the caught text, so the A/B compares Ring's wording
// against Ring++'s and not merely "both failed somehow".

func E1()
	a = [1, 2]
	try
		x = a[5]
		return "no error"
	catch
		return cCatchError
	done

func E2()
	a = [1, 2]
	try
		x = a[0]
		return "no error"
	catch
		return cCatchError
	done

func E3()
	a = [1, 2]
	try
		a[5] = 1
		return "no error"
	catch
		return cCatchError
	done

func E4()
	s = "ab"
	try
		x = s[9]
		return "no error"
	catch
		return cCatchError
	done

func E5()
	n = 5
	try
		x = len(n)
		return "no error"
	catch
		return cCatchError
	done

func E6()
	a = [1, 2]
	try
		x = ascii(a)
		return "no error"
	catch
		return cCatchError
	done

func E7()
	n = 5
	try
		x = upper(n)
		return "no error"
	catch
		return cCatchError
	done

func E8()
	n = 5
	try
		x = n % 0
		return "no error"
	catch
		return cCatchError
	done

func E9()
	a = [1, 2]
	try
		x = (a < 3)
		return "no error"
	catch
		return cCatchError
	done

func E10()
	a = [1, 2]
	try
		del(a, 9)
		return "no error"
	catch
		return cCatchError
	done

func E11()
	// caught and RECOVERED FROM: the point of not panicking is that the
	// program carries on
	a = [1, 2]
	n = 0
	try
		x = a[99]
	catch
		n = 1
	done
	return n + len(a)
