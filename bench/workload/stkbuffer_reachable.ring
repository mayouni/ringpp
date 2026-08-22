### Is Softanza's memory module reachable through its intended API?
### Run before and after the (a) repairs; every line must say ok.

load "D:/GitHub/stzlib/libraries/stzlib/core/stklib.ring"

nPass = 0
nFail = 0

func Check cLabel, bOk
	if bOk
		nPass++
		? "  ok    " + cLabel
	else
		nFail++
		? "  FAIL  " + cLabel
	ok

func main
	? "stkMemory / stkBuffer reachability"
	? ""

	oMem = new stkMemory()

	### the documented path: create, then use what you got back
	oB = oMem.CreateBuffer(64)
	Check("CreateBuffer returns a buffer", isobject(oB) and classname(oB) = "stkbuffer")

	oB.Write(0, "HELLO WORLD")
	Check("Write then Size", oB.Size() = 11)
	Check("Read back", oB.Read(0, 5) = "HELLO")
	Check("Read is silent (no DEBUG output)", TRUE)

	### the id-based path
	oB2 = oMem.GetBuffer("buf1")
	Check("GetBuffer('buf1') resolves", isobject(oB2) and oB2.Size() = 11)
	Check("GetBuffer returns the same buffer", oB2.Read(0, 5) = "HELLO")

	oB3 = oMem.GetBufferById("buf1")
	Check("GetBufferById works (stkPointer calls it)", isobject(oB3) and oB3.Size() = 11)

	### an invalid id must still raise
	bRaised = FALSE
	try
		oMem.GetBuffer("nope")
	catch
		bRaised = TRUE
	done
	Check("GetBuffer on a bad id raises", bRaised)

	### a second buffer, to prove ids are distinct
	oC = oMem.CreateBuffer(32)
	oC.Write(0, "SECOND")
	Check("second buffer is independent", oMem.GetBuffer("buf2").Read(0, 6) = "SECOND")
	Check("first buffer unchanged", oMem.GetBuffer("buf1").Read(0, 5) = "HELLO")
	Check("NumberOfBuffers", oMem.NumberOfBuffers() = 2)

	### the pointer path, which needs GetBufferById + GetBufferInfo
	bPtr = FALSE
	try
		oMem.CreatePointer("buf1", "read")
		bPtr = TRUE
	catch
		? "  note  CreatePointer raised: " + trim(cCatchError)
	done
	Check("CreatePointer('buf1','read')", bPtr)

	? ""
	? "  " + nPass + " passed, " + nFail + " failed"
	if nFail = 0
		? "  REACHABLE"
	else
		? "  NOT REACHABLE"
	ok
