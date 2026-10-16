$total = 0

func A1()
    o = new Counter
    o.Bump(5)
    o.Bump(7)
    return o.Value()

func A2()
    # a bare name is a LOCAL -- it cannot reach anything outside
    n = 3
    Helper()
    return n

func Helper()
    n = 999

func A3()
    $total = 10
    Adds()
    return $total

func Adds()
    $total = $total + 5

class Counter
    @n = 0

    def Bump(x)
        # @undeclared is an attribute even though the class body
        # never mentions it -- Rule A's pre-pass registers it
        @undeclared = 1
        @n = @n + x + @undeclared - 1

    def Value()
        return @n
