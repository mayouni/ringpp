# random() AND srandom() ARE C's rand() AND srand() -- 2026-10-05.
#
# Ring's random(n) is `rand() % (n + 1)` (vendor/ring-vm/src/math_e.c:463)
# and srandom(n) is srand(n). Ring seeds rand() from the clock in seconds as
# it starts (state.c:532), so only a seeded draw can be compared: after
# srandom(n) both runtimes draw C's own sequence for n. Ring++ drew from
# Zig's generator under a fixed seed -- the same numbers on every run, none
# of them Ring's -- answered 0 for a negative bound, refused `random()` with
# no argument, and returned 0 from srandom where Ring returns NULL.
#
# rand() is called FIRST, before the argument is looked at, so a call that
# raises still uses a number up: row 8 is the draw AFTER row 7's.
# Every row is the oracle's answer and official 1.27's.

srandom(1)
? "1 " + random(100) + " " + random(100) + " " + random(100)
? "2 " + random(0)
? "3 " + random(-5) + " " + random(-1)
? "4 " + random(2.9) + " " + random(1.5)
? "5 " + random()
srandom(7)
a = random(1000)
b = random(1000)
srandom(7)
? "6 " + (a = random(1000)) + " " + (b = random(1000))
srandom(1)
try
	random("a")
catch
	? "7 " + cCatchError
done
? "8 " + random(100)
try
	random(3000000000)
catch
	? "9 " + cCatchError
done
try
	srandom(-1)
catch
	? "10 " + cCatchError
done
? "11 [" + srandom(3) + "]"
? "12 " + random(10)
