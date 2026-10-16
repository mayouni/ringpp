$top = 100
$plain = 200
$c7 = 0
$c8 = 0
$c9 = 0

func G1()
    return $top

func G2()
    return $plain

func G3()
    return $top + $plain

func G4()
    return len(nl) + ascii(nl)

func G5()
    return ascii(tab) + ascii(cr)

func G6()
    x = 5
    return x

// G7-G9: `$g++` on a global. It was refused while `$g += 1` compiled --
// the same statement said differently -- so a program had to know which
// spelling this compiler happened to accept. Found by rpp/tui.ring, whose
// two line counters had to be written the long way, 2026-09-03.
//
// Each sets its OWN counter first, so calling them in any order or twice
// gives the same answer: the harness calls each function on its own, and
// a probe that leans on a sibling having run first reports a difference
// that is the probe's fault, not the compiler's (it did, once).
func G7()
	$c7 = 100
	$c7++
	$c7++
	return $c7

func G8()
	$c8 = 200
	$c8--
	return $c8

func G9()
	$c9 = 100
	$c9 += 5
	return $c9
