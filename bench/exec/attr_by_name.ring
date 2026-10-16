$b = new B
try ? "Q1 " + $b.x catch ? "Q1 err " + cCatchError done
try ? "Q2 " + $b.@ax catch ? "Q2 err " + cCatchError done
$d = new D
try ? "Q3 " + $d.y catch ? "Q3 err " + cCatchError done
try ? "Q4 " + $d.x catch ? "Q4 err " + cCatchError done
try ? "Q5 " + Fetch($d) catch ? "Q5 err " + cCatchError done
try ? "Q6 " + FetchAx($b) catch ? "Q6 err " + cCatchError done
try $b.x = 5  ? "Q7 " + $b.x catch ? "Q7 err " + cCatchError done
try ? "Q8 " + $b.nope catch ? "Q8 " + cCatchError done
func Fetch(q)
	return q.y
func FetchAx(q)
	return q.@ax
class B
	x = 1
	@ax = 3
class D from B
	y = 2
