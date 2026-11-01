# RUNG 3 OF THE RESIDENT VM: a running program REPLACES functions it holds
# (`replacecode`, `replacefile`) -- HaroServer's redeploy and the refinement
# loop's step. Run with `rnxc resident rp_host.ring`. Ring has no answer to
# compare with: it refuses a function defined twice (C22).
? "host: start"
? "admit lib: " + admitfile("rp_lib.ring")
? "before: " + Report(3) + ", " + Price(3) + ", " + Describe()

# the library's own call site, this file's call (compiled before Price
# existed), a call by name and eval all reach the replacement
? "replace: " + replacecode("price2", "func Price n" + nl + tab + "return n * 100" + nl)
? "after: " + Report(3) + ", " + Price(3)
f = "price"
? "by name: " + call f(3)
eval("? 'eval: ' + Price(3)")

# the replacement answers another kind of value than the code calling it
# was compiled against
? "replace kind: " + replacecode("kind2", "func Kind" + nl + tab + "return upper('seven') + lower('X')" + nl)
for i = 1 to 3
	? "describe: " + Describe()
next

# replaced again
? "again: " + replacecode("price3", "func Price n" + nl + tab + "return n * 1000" + nl)
? "after again: " + Report(3) + ", " + Price(3)

# refusals: each raises, and the program is as it was
try
	replacecode("bad1", "func Price a, b" + nl + tab + "return a" + nl)
	? "never printed"
catch
	? "arity: " + cCatchError
done
try
	replacecode("bad2", "func Prise n" + nl + tab + "return 0" + nl)
	? "never printed"
catch
	? "nothing: " + cCatchError
done
try
	replacecode("bad3", "func Price n" + nl + tab + "return f" + nl)
	? "never printed"
catch
	? "broken: " + cCatchError
done
try
	admitcode("bad4", "func Price n" + nl + tab + "return 0" + nl)
	? "never printed"
catch
	? "admit is not replace: " + cCatchError
done
? "still: " + Report(3)

# a function replaced while its frame runs
? Loop()
? Loop()

# replaced in the middle of its own recursion
Countdown(3)
? "countdown again"
Countdown(1)

# the redeploy: a file rewritten on disk, replaced by its path
write("rp_mod.ring", "func Greeting" + nl + tab + "return 'v1'" + nl)
? "admit mod: " + admitfile("rp_mod.ring")
? "mod: " + Greeting()
write("rp_mod.ring", "? 'mod v2: its top level runs'" + nl + "func Greeting" + nl + tab + "return 'v2'" + nl)
try
	admitfile("rp_mod.ring")
	? "never printed"
catch
	? "admit again: " + cCatchError
done
? "replace mod: " + replacefile("rp_mod.ring")
? "mod: " + Greeting()
remove("rp_mod.ring")
? "host: end"
