# The first file: functions, a global its top level declares, and a class --
# whose objects must still answer after later files grow the name table.
$nCount = 0
$oTally = new Tally
? "r01: " + Twice(21) + " " + $oTally.Plus(5)

func Twice n
	return n * 2

func Bump
	$nCount++
	return $nCount

class Tally
	nSum = 0

	func Plus n
		nSum += n
		return nSum
