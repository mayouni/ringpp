? "=== definition without parens"
? "  F1 5      = " + F1(5)
? "  F2()      = " + F2()

? ""
? "=== CALL without parens?"
try
    eval('x = F1 5')
    ? "  F1 5 (no parens) -> accepted"
catch
    ? "  F1 5 (no parens) -> REJECTED: " + cCatchError
done
try
    eval('x = F2')
    ? '  x = F2 -> accepted, x is ' + type(x)
catch
    ? "  x = F2 -> REJECTED: " + cCatchError
done

? ""
? "=== what about a builtin?"
try
    eval('x = len "abc"')
    ? '  len "abc" -> accepted'
catch
    ? '  len "abc" -> REJECTED: ' + cCatchError
done

func F1 n
    return n * 2

func F2
    return 7
