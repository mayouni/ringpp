// The map type's acceptance probe, run UNCHANGED on Ring 1.27 and on
// Ring++ so the two are measured the same way. Two numbers the charter
// fixed in advance: memory at 200,000 entries (target under 20 MB against
// Ring's 73 MB; above 40 MB the claim is withdrawn) and keyed lookup
// (target under 0.10 us against Ring's 0.15 us; else the speed claim is
// dropped, not defended).
//
// Memory is sampled from OUTSIDE by bench/memsample.py while this holds
// the data and does its lookups, so the process must not exit early.

$N = 200000
$M = 1000000

$h = []
$t0 = clock()
for $i = 1 to $N
	$h + [ "key" + $i, $i ]
next
$t1 = clock()
? "built " + len($h) + " entries in " + ($t1 - $t0) + " ms"

// keyed lookups, spread across the whole table so a cache cannot flatter it
$sum = 0
$t2 = clock()
for $j = 1 to $M
	$k = "key" + ((($j * 7919) % $N) + 1)
	$sum = $sum + $h[$k]
next
$t3 = clock()
$us = (($t3 - $t2) * 1000.0) / $M
? "lookups " + $M + " in " + ($t3 - $t2) + " ms = " + $us + " us each   (checksum " + $sum + ")"

// a missing key: read-never-writes on Ring++, insert on Ring -- the
// registered divergence, made visible rather than hidden
$before = len($h)
$v = $h["no-such-key"]
? "missing key read: len " + $before + " -> " + len($h) + "   (Ring inserts; Ring++ does not)"

// positional access must keep working -- 3,429 sites depend on it
? "positional: h[1][1] = " + $h[1][1] + ", h[1][2] = " + $h[1][2]
? "MAP200K DONE"
