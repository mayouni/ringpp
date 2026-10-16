? "=== 1. does an anonymous function CLOSE OVER a local?"
n = 42
f = func() { return n }
try
    ? "  f() = " + call f()
catch
    ? "  f() -> " + cCatchError
done

? ""
? "=== 2. passed as an argument"
g = func(x) { return x * 2 }
? "  Apply(g, 5) = " + Apply(g, 5)

? ""
? "=== 3. returned from a function -- does it keep its environment?"
h = MakeAdder(10)
try
    ? "  MakeAdder(10) then call h(5) = " + call h(5)
catch
    ? "  -> " + cCatchError
done

func Apply(fn, v)
    return call fn(v)

func MakeAdder(k)
    return func(x) { return x + k }
