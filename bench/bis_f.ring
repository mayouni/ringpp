// Bisection F: global append at N, N passed in by `rnxc call`. Returns
// the LAST pair's value read positionally, which is N when the pairs are
// intact and raises R24 when they are not. Sweeping N finds the
// threshold: a power of two implicates the buffer-growth path, anything
// fuzzy implicates memory reuse.

func BuildN(n)
	$gf = []
	for $if = 1 to n
		$gf + [ "key" + $if, $if ]
	next
	return $gf[n][2]

func KeyedN(n)
	$gk = []
	for $ik = 1 to n
		$gk + [ "key" + $ik, $ik ]
	next
	return $gk["key" + n]
