### Real-workload baseline — Softanza's stkBuffer.Write
###
### stkBuffer stores its bytes in an ordinary Ring string and rebuilds it on
### every write:
###     @buffer = left(@buffer, nOffset) + cData + right(@buffer, ...)
### That is O(size) per write however few bytes are written — FINDINGS F-7.
###
### NOTE the construction path. stkMemory.CreateBuffer() returns 1 rather
### than the buffer, and stkMemory.GetBuffer() reads an attribute that does
### not exist (@aBufferId instead of @aBuffers), so it always raises. The
### only working route today is constructing stkBuffer directly.

load "D:/GitHub/stzlib/libraries/stzlib/core/stklib.ring"

func Ms t1,t2  return (t2-t1)/clockspersecond()*1000

func Pad c, n
	if len(c) >= n return c ok
	return c + copy(" ", n - len(c))

func main
	? "stkBuffer.Write baseline (unmodified Softanza, Ring 1.27)"
	? ""
	? "  buffer     writes   total      per write"

	oMem = new stkMemory()
	nWrites = 500

	for nSize in [1000, 10000, 100000]
		oB = new stkBuffer(oMem, "b" + nSize, nSize)
		oB.Write(0, copy("x", nSize))          # fill, so the writes are overwrites

		t1 = clock()
		for i = 1 to nWrites
			nOff = ((i * 7919) % (nSize - 16))
			oB.Write(nOff, "PATCHED!")
		next
		t2 = clock()
		nMs = Ms(t1,t2)
		? "  " + Pad("" + nSize, 10) + " " + Pad("" + nWrites, 8) + " " +
		  Pad("" + nMs + " ms", 10) + " " + (nMs*1000/nWrites) + " us"
	next

	? ""
	? "  Each write copies the whole buffer twice (left + right), so the cost"
	? "  scales with the buffer, not with the 8 bytes being written."
