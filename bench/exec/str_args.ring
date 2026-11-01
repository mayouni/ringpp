# A builtin handed something other than a STRING where it wants one raises on
# Ring -- "Bad parameter type!", catchable -- and never panics here. Five shapes
# did: strcmp's second argument, substr(n, "x") and substr(n, v) with a number
# to search, and substr's three-argument forms with a mixed pair (strOf and
# asInt panicked, which no try catches). Measured on the oracle and on official
# 1.27, which agree on every row (2026-10-30); found by the stzlib OCR desk, whose
# guard clobbered `nl` with a number before library code read it.
#
# Ring's substr rules (genlib_e.c:884), pinned while here: two numbers are a
# substring and two strings a replace; a replace with an empty needle is "Bad
# parameter value!"; the FOURTH argument -- a call to a function nothing defined
# until now (R3) -- is 0 for the three-argument call, 1 for a replace that
# ignores case, any other number "", anything else "Bad parameter type!"; and
# any other count is "Bad parameters count!". And ascii() takes a string only:
# it took an integer too while s[i] was a byte (F-54, before C-3).
nV = 5
cX = "b"
try  ? "1 " + strcmp("a", 5)                   catch  ? "1 " + cCatchError  done
try  ? "2 " + strcmp(5, "a")                   catch  ? "2 " + cCatchError  done
try  ? "3 " + strcmp("a", [1])                 catch  ? "3 " + cCatchError  done
try  ? "4 " + substr(5, "b")                   catch  ? "4 " + cCatchError  done
try  ? "5 " + substr(5, nV)                    catch  ? "5 " + cCatchError  done
try  ? "6 " + substr(5, cX)                    catch  ? "6 " + cCatchError  done
try  ? "7 " + substr([1], "b")                 catch  ? "7 " + cCatchError  done
try  ? "8 " + substr("abc", "b", 5)            catch  ? "8 " + cCatchError  done
try  ? "9 " + substr("abc", 5, "x")            catch  ? "9 " + cCatchError  done
try  ? "10 " + substr("abc", "", "x")          catch  ? "10 " + cCatchError  done
try  ? "11 " + substr("abc", "b", "x")         catch  ? "11 " + cCatchError  done
try  ? "12 " + substr("abc", "")               catch  ? "12 " + cCatchError  done
try  ? "13 " + substr("abcdef", 2, 3)          catch  ? "13 " + cCatchError  done
try  ? "14 [" + substr("abc", 2, 0) + "]"      catch  ? "14 " + cCatchError  done
try  ? "15 " + substr("aBcbB", "b", "x", 1)    catch  ? "15 " + cCatchError  done
try  ? "16 " + substr("aBcbB", "b", "x", 0)    catch  ? "16 " + cCatchError  done
try  ? "17 [" + substr("aBcbB", "b", "x", 2) + "]"  catch  ? "17 " + cCatchError  done
try  ? "18 " + substr("abcdef", 2, 3, 0)       catch  ? "18 " + cCatchError  done
try  ? "19 " + substr("abcdef", 2, 3, 1)       catch  ? "19 " + cCatchError  done
try  ? "20 " + substr("abc", "b", "x", "1")    catch  ? "20 " + cCatchError  done
try  ? "21 " + substr(5, "b", "x", 1)          catch  ? "21 " + cCatchError  done
try  ? "22 " + substr("abc", 5, "x", 1)        catch  ? "22 " + cCatchError  done
try  ? "23 " + substr("abc", "b", 5, 1)        catch  ? "23 " + cCatchError  done
try  ? "24 " + substr("abc", "", "x", 1)       catch  ? "24 " + cCatchError  done
try  ? "25 " + substr("aBc", "B", "", 1)       catch  ? "25 " + cCatchError  done
try  ? "26 " + substr("aBcB", "b", "yy", 1)    catch  ? "26 " + cCatchError  done
try  ? "27 " + substr("abc", "b", "x", 1.0)    catch  ? "27 " + cCatchError  done
try  ? "28 [" + substr("abc", "b", "x", 1.5) + "]"  catch  ? "28 " + cCatchError  done
try  ? "29 " + substr("abc", 5, "x", 0)        catch  ? "29 " + cCatchError  done
try  ? "30 " + ascii(5)                        catch  ? "30 " + cCatchError  done
try  ? "31 " + ascii("A")                      catch  ? "31 " + cCatchError  done
try  ? "32 " + ascii([1])                      catch  ? "32 " + cCatchError  done
try  ? "33 " + substr("abc")                   catch  ? "33 " + cCatchError  done
try  ? "34 " + substr("abc", "b", "x", 1, 2)   catch  ? "34 " + cCatchError  done
nl = 77
try  ? "35 " + substr("a" + char(10) + "b", nl, "|")  catch  ? "35 " + cCatchError  done
? "and uncaught:"
? substr(5, "b")
