func TestChar()
    return ascii(char(65))

func TestLower()
    s = lower("HeLLo")
    return ascii(s[1]) + ascii(s[5])

func TestTrim()
    return len(trim("  hi  "))

func TestLeftRight()
    return len(left("hello", 3)) * 10 + len(right("hello", 2))

func TestCopy()
    return len(copy("ab", 4))

func TestMaxMin()
    return max(3, 9) * 100 + min(3, 9)

func TestFabs()
    return fabs(0 - 42)

func TestNumber()
    return number("123") + 1

// BI_IDX: `s[i]` on a STRING, with no ascii() around it. Every other
// probe in this tree wraps it -- ascii(s[i]) is the same on both runtimes
// -- which is exactly why this divergence went unregistered until it
// escaped "amina" to "9710910511097" inside rpp/tui.ring, 2026-09-04.
func BI_IDX()
	s = "abc"
	return "" + s[2]
