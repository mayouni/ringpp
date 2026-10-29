# shutdown(n): end the program HERE with exit code n -- inside a function, an if, a loop; nothing after it runs
# (Ring, os_e.c:235). A guard ends with `shutdown($nFail)` so its exit code says what its last line says; this VM had
# no such builtin (R3), so a guard died on its LAST line, after printing its verdict. bench/exec.py compares output only,
# so the exit code is checked by hand: `ring shutdown.ring` and `rnxc shutdown.ring` both exit 7.
try
	shutdown("x")
catch
	? "caught: " + cCatchError
done
try
	shutdown(1, 2)
catch
	? "caught: " + cCatchError
done
try
	shutdown(99999999999)
catch
	? "caught: " + cCatchError
done
? "top: before"
Inner()
? "top: NOT REACHED"

func Inner
	? "inner: before"
	for k = 1 to 3
		if k = 2
			shutdown(7)
		ok
		? "inner: k = " + k
	next
	? "inner: NOT REACHED"
