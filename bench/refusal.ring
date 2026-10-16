// A refused statement must RAISE where it stood, not be skipped.
//
// Measured 2026-09-04, before rnxc did that: a program of this shape
// printed "acc is now: 0" and ran to the end, while Ring 1.27 printed
// "acc is now: 7". The RETURN VALUE was right at the call site -- 5 on
// both -- and only the side effect was missing, which is why it hid so
// long. The census knew (`1 refused`); the runtime did not act on it.
// F-50 in ringpp/docs/FINDINGS.md.
//
// THE REFUSED CONSTRUCT HERE is an `@attribute` read outside any class --
// refused by Rule A, because an attribute with no class has no meaning
// (on Ring it is a plain local). It was `$acc++` until 2026-09-04, `call
// fAdd(7)` until 2026-09-09 and `cCatchError` outside a catch until
// 2026-09-24 (C-15 made that read Ring's process-wide value), each fixed
// and each time the gate step said so rather than going green by
// accident. WHAT THIS GUARDS IS THE RAISE, not any one construct: point it
// at another refusal, never delete it.
$acc = 0
$v = Total(2, 3)
? "returned: " + $v
? "acc is now: " + $acc
? "REFUSAL PROBE REACHED THE END"

func Total(a, b)
	// the side effect sits INSIDE the refused statement, so a skip shows
	// as acc staying 0 and a raise shows as the end never being reached
	$acc = $acc + 7 + len(@cNoClassHere)
	return a + b
