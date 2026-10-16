// Memory of the REPRESENTATION: 200,000 pairs, one keyed lookup so the
// index exists, then a long loop that allocates nothing so the sampler
// can read the peak. No transient strings in the timed region -- map200k
// built a million of them and measured those too. Run unchanged on Ring
// 1.27 and Ring++.

$N = 200000
$h = []
for $i = 1 to $N
	$h + [ "key" + $i, $i ]
next
$v = $h["key7920"]
? "built " + len($h) + " entries; index built by one lookup (" + $v + ")"

// hold the data for ~2 s without allocating: positional reads only
$sum = 0
$t0 = clock()
while clock() - $t0 < 2000
	for $j = 1 to 1000
		$sum = $sum + $h[$j][2]
	next
end
? "held; checksum " + $sum
? "MEM DONE"
