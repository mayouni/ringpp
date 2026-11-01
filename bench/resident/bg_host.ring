# RUNG 9, AN ADMISSION COMPILED IN THE BACKGROUND, ON THE RESIDENT VM. admitstart(cVerb, ...) takes a verb -- admitfile,
# admitcode, replacefile, replacecode, admitapp or replaceapp -- and that verb's own arguments, starts the admission's
# compile on a thread of its own and returns; the program runs on; admitstate() says "compiling" or "compiled" ("" when
# none was started), admitstate(nWaitMs) after waiting at most that long; admitfinish() waits if it must, then installs
# it and runs its top level where the call stands -- the same admission the verb makes, admitted or refused as the verb
# would have been. One compiles at a time: while it does, every other admission and release is refused. Run with
# `rnxc resident bg_host.ring`. Golden: Ring has no resident VM.
? "host: start"
? "state before any: [" + admitstate() + "]"

# 1. code compiled in the background while the program works, installed by admitfinish()
cLib = "? '  lib: its top level runs at admitfinish()'" + nl +
	"func Twice x" + nl + tab + "return x * 2" + nl
? "start lib: " + admitstart("admitcode", "lib", cLib)
? "the program works meanwhile: " + Work(2000)
? "state while started: " + Started()
? "finish lib: " + admitfinish()
? "Twice(21): " + Twice(21)
? "state after: [" + admitstate() + "]"

# 2. refused as the verb refuses: the same reason, raised by admitfinish(), the program as it was
cBad = "nBadGlobal = 1" + nl + "func BadOne" + nl + tab + "return 1" + nl + "func Bad" + nl + tab + "return nBadGlobal" + nl
try
	admitcode("bad", cBad)
catch
	? "the verb: " + cCatchError
done
? "start bad: " + admitstart("admitcode", "bad", cBad)
try
	admitfinish()
	? "never printed"
catch
	? "admitfinish: " + cCatchError
done
? "after the refusal: BadOne defined " + isfunction("BadOne") + ", Twice(5) " + Twice(5)

# 3. one at a time: while one compiles, every other admission and release is refused
? "start slow: " + admitstart("admitcode", "slow", Many("Slow", 300))
Refused("admitcode meanwhile", 1)
Refused("admitstart meanwhile", 2)
Refused("releasecode meanwhile", 3)
Refused("admitapp meanwhile", 4)
? "finish slow: " + admitfinish() + ", Slow300() " + Slow300()
try
	admitfinish()
catch
	? "finish again: " + cCatchError
done

# 4. a verb it does not take, and a verb given the wrong arguments
try
	admitstart("releasecode", "lib")
catch
	? "a release: " + cCatchError
done
try
	admitstart("admitcode", "x")
catch
	? "too few: " + cCatchError
done
try
	admitstart("admitfile", "a.ring", "b")
catch
	? "too many: " + cCatchError
done

# 5. every verb: a file, a replacement of code and of a file, an app and its replacement
write("bg_tmp.ring", "? '  file v1: its top level runs'" + nl + "func FileSays" + nl + tab + "return 'v1'" + nl)
admitstart("admitfile", "bg_tmp.ring")
? "admitfile: " + admitfinish() + ", FileSays() " + FileSays()
write("bg_tmp.ring", "? '  file v2: its top level runs'" + nl + "func FileSays" + nl + tab + "return 'v2'" + nl)
admitstart("replacefile", "bg_tmp.ring")
? "replacefile: " + admitfinish() + ", FileSays() " + FileSays()
remove("bg_tmp.ring")
admitstart("replacecode", "lib2", "func Twice x" + nl + tab + "return x * 20" + nl)
? "replacecode: " + admitfinish() + ", Twice(21) " + Twice(21)
cShop = "func Price" + nl + tab + "return 7" + nl + "func Secret" + nl + tab + "return 'kept'" + nl
admitstart("admitapp", "shop", cShop, ["Price"])
? "admitapp: " + admitfinish() + ", shop.Price() " + Call0("shop.Price") + ", shop::Secret() " + Call0("shop::Secret")
admitstart("replaceapp", "shop", "func Price" + nl + tab + "return 70" + nl)
? "replaceapp: " + admitfinish() + ", shop.Price() " + Call0("shop.Price")

# the program's first class, admitted in the background: the compile builds the VM's class tables whole, and only the
# install, on the program's thread, hands them to the VM
cShapes = "func MakeSq" + nl + tab + "return new Sq" + nl +
	"class Sq" + nl + tab + "n = 3" + nl + tab + "func Area" + nl + tab + tab + "return n * n" + nl
admitstart("admitcode", "shapes", cShapes)
? "a first class: " + admitfinish() + ", MakeSq().Area() " + MakeSq().Area()

# 6. its top level raises: the error comes back at admitfinish(), catchable, and what it defined stays
admitstart("admitcode", "raiser", "raise('from its top level')" + nl + "func Kept" + nl + tab + "return 'kept'" + nl)
try
	admitfinish()
	? "never printed"
catch
	? "raised at admitfinish: " + cCatchError
done
? "Kept(): " + Kept()

# 7. classes admitted in the background while the program attaches a method to a class it holds (addmethod): the
#    compiling thread prepares the new classes' rows numbered after the method table it found, addmethod grows that
#    table, and the install builds the rows itself -- every method answers as the verb's admission would have
oSq = MakeSq()
cMore = Many("More", 300) + "func MakeCube" + nl + tab + "return new Cube" + nl +
	"class Box" + nl + tab + "s = 2" + nl + tab + "func Side" + nl + tab + tab + "return s" + nl +
	"class Cube from Box" + nl + tab + "func Vol" + nl + tab + tab + "return Side() * Side() * Side()" + nl
admitstart("admitcode", "more", cMore)
addmethod(oSq, "Twice", "SqTwice")
? "attached while it compiles: " + oSq.Twice()
? "finish more: " + admitfinish() + ", MakeCube().Vol() " + MakeCube().Vol() + ", Side() " + MakeCube().Side() + ", oSq.Twice() " + oSq.Twice()

# 8. the current directory stays where the program stood when it called admitstart: chdir() waits for the compile,
#    which reads the root's loads and a relative path against it, as the verb does -- the code is large, so the load
#    is read well after the chdir would have moved it
write("bg_cd.ring", "func FromHere" + nl + tab + "return 'here'" + nl)
admitstart("admitcode", "cd", "load 'bg_cd.ring'" + nl + Many("Cd", 3000))
? "chdir while it compiles: " + chdir("..")
try
	? "then admitfinish: " + admitfinish() + ", FromHere() " + FromHere()
catch
	? "then admitfinish: " + cCatchError
done
chdir("resident")
remove("bg_cd.ring")

# 9. it waits: admitstate(nWaitMs) waits at most that long, admitfinish() as long as it takes
admitstart("admitcode", "waited", Many("Waited", 300))
st = admitstate(60000)
? "after waiting: " + st
? "finish waited: " + admitfinish() + ", Waited1() " + Waited1()
? "state at the end: [" + admitstate() + "]"
? "host: done"

func Work n
	nSum = 0
	for i = 1 to n
		nSum += i % 7
	next
	return nSum

func Started
	st = admitstate()
	return st = "compiling" or st = "compiled"

# n functions `<cName>1() ... <cName>n()`, each answering its number -- a compile that takes a while
func Many cName, n
	cSrc = ""
	for i = 1 to n
		cSrc += "func " + cName + i + nl + tab + "x = " + i + nl + tab + "y = x * 2 + 1" + nl + tab + "return x" + nl
	next
	return cSrc

func Refused cWhat, nWhich
	try
		switch nWhich
		on 1
			admitcode("other", "func Other" + nl + tab + "return 1" + nl)
		on 2
			admitstart("admitcode", "other", "func Other" + nl + tab + "return 1" + nl)
		on 3
			releasecode("lib")
		on 4
			admitapp("other", "func Other" + nl + tab + "return 1" + nl, [])
		off
		? cWhat + ": never printed"
	catch
		? cWhat + ": " + cCatchError
	done

func Call0 cName
	return call cName()

# attached to Sq by addmethod: a plain function, This the receiver
func SqTwice
	return This.Area() * 2
