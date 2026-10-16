// Lookup ONLY. map200k timed a loop that also built a key string per
// iteration, on both sides -- fair, but not what the charter's 0.10 us
// names. Here the keys are built once, and the timed loop does one
// indexed read of the key list and one keyed lookup. Run unchanged on
// Ring 1.27 and Ring++.

$N = 200000
$M = 1000000

$h = []
for $i = 1 to $N
	$h + [ "key" + $i, $i ]
next

$keys = []
for $i = 1 to $N
	$keys + ("key" + ((($i * 7919) % $N) + 1))
next
? "built " + len($h) + " entries and " + len($keys) + " probe keys"

$sum = 0
$t0 = clock()
for $j = 1 to $M
	$sum = $sum + $h[ $keys[ (($j - 1) % $N) + 1 ] ]
next
$t1 = clock()
$us = (($t1 - $t0) * 1000.0) / $M
? "lookup-only " + $M + " in " + ($t1 - $t0) + " ms = " + $us + " us each   (checksum " + $sum + ")"
? "LOOKUP DONE"
