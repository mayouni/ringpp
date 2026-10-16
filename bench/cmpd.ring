// Compound assignment -- `+= -= *= /=` on every assignable PLACE.
//
// Ring accepts all four on a local, a global, an attribute and an
// ELEMENT. This compiler had a different set at each: `$g += 1` but not
// `$g *= 2`, `n *= 2` but not `n /= 2`, and none at all on `a[i]`.
// Measured 2026-09-04; `a[i] += x` was 69 of the 933 refusals.
//
// Each function sets up its OWN state, so any order and any repetition
// give the same answer: the harness calls each on its own, and a probe
// that leans on a sibling reports a difference that is the probe's fault.
$cg = 0

func C1()
	$cg = 100
	$cg += 1
	$cg -= 2
	$cg *= 3
	$cg /= 4
	return $cg

func C2()
	n = 100
	n += 1
	n -= 2
	n *= 3
	n /= 4
	return n

func C3()
	a = [100]
	a[1] += 1
	a[1] -= 2
	a[1] *= 3
	a[1] /= 4
	return a[1]

func C4()
	m = [ [1, 2], [3, 4] ]
	m[1][2] += 100
	return m[1][2]

func C5()
	h = [ :n = 1 ]
	h[:n] += 9
	return h[:n]

// `+` is polymorphic and so is `+=`: on a STRING element it concatenates,
// exactly as Ring's does.
func C6()
	s = [ "ab", "cd" ]
	s[1] += "XY"
	return s[1]

func C7()
	o = new CmpdK
	return o.Run()

// C8/C9: `+=` and `++` on a LIST. Ring raises R21 for both -- compound
// assignment is NOT the same operator as `+`, which appends -- and Ring++
// appended for either until 2026-09-04 (F-51), in every kind of place.
//
// These could not be A/B cases while they diverged: Ring raised, so there
// was no output to compare, and C8 sat here uncalled. Now that both
// runtimes raise, try/catch turns the raise itself into the answer, and
// they are ordinary gated probes like the rest.
func C8()
	a = [ [1, 2], [3] ]
	r = ""
	try
		a[2] += 9
		r = "appended " + len(a[2])
	catch
		r = "raised"
	done
	return r

func C9()
	a = [ 1, 2 ]
	r = ""
	try
		a++
		r = "appended " + len(a)
	catch
		r = "raised"
	done
	return r

// and the other half of F-51: plain `+` MUST still append.
func C10()
	a = [ 1, 2 ]
	b = a + 9
	return "len " + len(b)

class CmpdK
	@v = 0

	def Run()
		@v = 100
		@v += 1
		@v -= 2
		@v *= 3
		@v /= 4
		return @v
