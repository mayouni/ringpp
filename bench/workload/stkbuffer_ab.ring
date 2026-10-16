### A/B for stkBuffer.Write's in-place path.
###
### Run twice: once as shipped, once with @nInPlaceMin raised above every
### buffer size below (which disables the fast path and restores the
### rebuild). The two runs differ in exactly one thing.
###
###   ring stkbuffer_ab.ring
###
### 20,000 writes per size, because Ring's clock() has 1 ms resolution and
### 500 writes landed in the noise.

load "D:/GitHub/stzlib/libraries/stzlib/core/stklib.ring"

func Ms t1,t2  return (t2-t1)/clockspersecond()*1000

func Pad c, n
	if len(c) >= n return c ok
	return c + copy(" ", n - len(c))

func main
	oMem = new stkMemory()
	nWrites = 20000

	? "stkBuffer.Write -- " + nWrites + " overwrites of 8 bytes"
	? ""
	? "  buffer        total        per write"

	for nSize in [1000, 10000, 100000, 1000000]
		oB = new stkBuffer(oMem, "b" + nSize, nSize)
		oB.Write(0, copy("x", nSize))

		t1 = clock()
		for i = 1 to nWrites
			nOff = ((i * 7919) % (nSize - 16))
			oB.Write(nOff, "PATCHED!")
		next
		t2 = clock()
		nMs = Ms(t1,t2)
		? "  " + Pad("" + nSize, 12) + " " + Pad("" + nMs + " ms", 12) + " " +
		  (nMs*1000/nWrites) + " us"
	next

	### correctness: the bytes must actually land
	oC = new stkBuffer(oMem, "chk", 4096)
	oC.Write(0, copy("-", 4096))
	oC.Write(100, "ABCD")
	oC.Write(4092, "WXYZ")
	? ""
	? "  write at 100  : [" + oC.Read(100, 4) + "]   expected [ABCD]"
	? "  write at 4092 : [" + oC.Read(4092, 4) + "]   expected [WXYZ]"
	? "  length kept   : " + oC.Size() + "   expected 4096"
	? "  binary source : " + str2hex(oC.Read(200, 4))
	oC.Write(200, int2bytes(256))          # leading zero byte -- F-14 shape
	? "  after i2b(256): " + str2hex(oC.Read(200, 4)) + "   expected 00010000"
