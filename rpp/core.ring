### Ring++ — RppBuffer and RppView.
###
### THE INVARIANT everything rests on:
###   an RppBuffer owns a Ring string created ONCE and never reassigned.
###
### varptr() returns a pointer into the String's own buffer. ring_string_add2
### reallocates on growth and ring_string_set2 reallocates past capacity —
### either moves the bytes and leaves a cached address dangling, which is a
### silent wrong answer or a hard crash. So the backing string is written only
### through the pointer, and Grow() means a NEW buffer plus an explicit copy.
###
### Bounds are checked HERE, in Ring, before the primitive runs. After the
### primitive there is nothing left to check: an over-read returns adjacent
### heap with no error, and an over-write kills the process with no message
### and no line number, uncatchable. See docs/FINDINGS.md Part 5.

### Two different crossovers. They are two orders of magnitude apart, and
### confusing them is how you ship a regression (docs/PHASE_PLAN.md P2).
RPP_MEMCPY_CROSSOVER = 512     # RAW memcpy vs +=, chunk size (FINDINGS F-8)
RPP_POKE_CROSSOVER   = 65536   # the CHECKED API vs +=: a method call costs
                               # ~340 ns against raw memcpy's ~280 ns, so Poke
                               # only wins on very large chunks. Building a
                               # string? Use +=. Poke is for random access.
RPP_INDEX_MIN_READS  = 20      # reads per mutation for genarray to pay (F-10)
RPP_INDEX_MIN_SIZE   = 64      # below this the cursor walk beats the array
RPP_NUL_BYTE         = char(0)   # cached: char() is a C call (F-4)

func RppBuffer nBytes
	return new RppBuffer(nBytes)

func RppBufferQ nBytes
	return new RppBuffer(nBytes)

func RppBufferFromString cStr
	oB = new RppBuffer(max([1, len(cStr)]))
	if len(cStr) > 0
		oB.PokeString(0, cStr)
	ok
	return oB

class RppBuffer

	### PREFIXED, AND THAT IS A BUG FIX. These were cData/nCap/pScratch/
	### pSrcPtr/cNul. In Ring an attribute assignment inside a class can
	### resolve against a CALLER's variable of the same name and destroy it:
	### a caller holding its own `cData` had it silently replaced by this
	### buffer's backing string, and `nCap` by this buffer's capacity.
	### `cData` is one of the commonest names in exactly the data-processing
	### code Ring++ is for. Same root cause as RppView below; found by
	### writing examples/05. See FINDINGS F-25.
	cRppData          # the backing string, written only through a live pointer
	nRppCap  = 0
	pRppScratch       # reusable c-pointers, so Poke/Peek allocate nothing
	pRppSrcPtr        # (nullptr() costs ~520 ns per call — FINDINGS F-4)
	cRppNul           # RPP_NUL_BYTE cached as an attribute: reading a GLOBAL
	               # from inside a method is slower than an attribute read

	### THE ADDRESS IS NOT CACHED, AND THAT IS DELIBERATE.
	###
	### An earlier version stored it once in init(). That is wrong, because
	### Ring copies an object when it is put in a list or assigned:
	###
	###     aBufs + RppBuffer(64)      # stores a COPY
	###
	### the copy carries the original's address, the original is a temporary
	### that dies, and every later write goes through a dangling pointer into
	### freed memory. It does not raise -- the process simply vanishes, with
	### no message and no line number (FINDINGS Part 5). It survived a
	### 100,000-access fuzz for days before the allocator reused the block.
	###
	### Re-deriving costs ~0.8 us per call and is correct by construction: a
	### copy resolves its OWN cRppData, so it writes to its own bytes.
	func Base
		return getptr(varptr(:cRppData, "char *"))

	func init nBytes
		if not isnumber(nBytes) or nBytes < 1
			raise("Rpp: buffer size must be a positive number, got " + nBytes)
		ok
		cRppData = space(nBytes)
		nRppCap = nBytes
		pRppScratch = nullptr()
		pRppSrcPtr  = nullptr()
		cRppNul     = RPP_NUL_BYTE

	func Capacity
		return nRppCap

	func Size
		return nRppCap

	### ---- reading ----

	# The O(1) slice. 0.09 us where substr() costs 12.5 us on 500 KB (F-6).
	func Peek nOffset, nLen
		This.CheckRange(nOffset, nLen, "Peek")
		setptr(pRppScratch, This.Base() + nOffset)
		return ptr2str(pRppScratch, 0, nLen)

	func Byte nOffset
		This.CheckRange(nOffset, 1, "Byte")
		return ascii(This.Peek(nOffset, 1))

	# The explicit exit back to an ordinary Ring string. Named so the copy is
	# visible at the call site.
	func Str
		return This.Peek(0, nRppCap)

	### ---- writing ----

	func Poke nOffset, cBytes
		nL = len(cBytes)
		# The guard is inlined: a method call costs ~70 ns, which is most of a
		# memcpy. CheckRange is entered only to build the message and raise.
		# isstring() is NOT in the hot condition: it is a C call (~43 ns) on a
		# path whose whole budget is one memcpy. len() above already rejects a
		# non-string, and the error branch below names it properly.
		if nOffset < 0 or nL < 0 or nOffset + nL > nRppCap
			if not isstring(cBytes)
				raise("Rpp: Poke expects a string, got " + type(cBytes))
			ok
			This.CheckRange(nOffset, nL, "Poke")
		ok
		if nL = 0 return ok
		setptr(pRppScratch, This.Base() + nOffset)
		# FINDINGS F-14 / ring-lang/ring#1643: on Ring <= 1.27, memcpy() aborts
		# the process when the SOURCE string's first byte is zero, or when it is
		# the literal "NULL" — strcmp() mistakes both for a NULL pointer. Only
		# those two shapes need the slow pointer route; everything else can hand
		# the string straight to memcpy and save a varptr (790 ns) plus a
		# nullptr (520 ns) per call.
		#
		# F-31: what strcmp() sees is the C view of the source, NOT the Ring
		# value, so the test must be on the bytes. Any string that BEGINS
		# "NULL" followed by a zero byte is `"NULL"` to strcmp whatever its
		# Ring length -- a 511-byte buffer starting NULL\0 killed the process
		# here, because the old test only recognised the literal 4-byte case.
		# Found by tests/differential.ring, 2026-08-25.
		#
		# Compared byte by byte on purpose: left(cBytes, 4) would pass the
		# whole string by value and pay the F-5 copy on every single Poke,
		# while s[i] is ~0.07 us and does not copy.
		#
		# Written as one expression because Ring's `and`/`or` DO short-circuit
		# (F-32) -- so cBytes[5] is never evaluated when nL is 4, and an
		# ordinary payload leaves the chain at the second test. The obvious
		# alternative, a flag assigned across nested ifs, measured 0.32 us
		# slower per Poke.
		if cBytes[1] = cRppNul or
		   (nL >= 4 and cBytes[1] = "N" and cBytes[2] = "U" and
		    cBytes[3] = "L" and cBytes[4] = "L" and
		    (nL = 4 or cBytes[5] = cRppNul))
			setptr(pRppSrcPtr, getptr(varptr(:cBytes, "char *")))
			memcpy(pRppScratch, pRppSrcPtr, nL)
		else
			memcpy(pRppScratch, cBytes, nL)
		ok

	func PokeString nOffset, cStr
		This.Poke(nOffset, cStr)

	func Fill nOffset, nLen, nByte
		This.CheckRange(nOffset, nLen, "Fill")
		if nLen = 0 return ok
		This.Poke(nOffset, copy(char(nByte), nLen))

	### ---- packed numbers ----

	func PokeInt32 nOffset, nValue
		This.Poke(nOffset, int2bytes(nValue))

	func PeekInt32 nOffset
		return bytes2int(This.Peek(nOffset, 4))

	func PokeDouble nOffset, nValue
		This.Poke(nOffset, double2bytes(nValue))

	func PeekDouble nOffset
		return bytes2double(This.Peek(nOffset, 8))

	func PokeFloat nOffset, nValue
		This.Poke(nOffset, float2bytes(nValue))

	func PeekFloat nOffset
		return bytes2float(This.Peek(nOffset, 4))

	### ---- views: a window, not a copy ----

	func View nOffset, nLen
		This.CheckRange(nOffset, nLen, "View")
		return new RppView(This, nOffset, nLen)

	func All
		return This.View(0, nRppCap)

	### ---- growth: the only legal resize ----

	func Grow nNewBytes
		if nNewBytes <= nRppCap
			raise("Rpp: Grow must increase the size — have " + nRppCap + ", asked " + nNewBytes)
		ok
		cOld = This.Peek(0, nRppCap)     # one explicit copy out
		nOldCap = nRppCap
		cRppData = space(nNewBytes)      # a NEW string; the old address is dead
		nRppCap = nNewBytes
		This.Poke(0, cOld)
		return nOldCap

	### ---- files ----

	func LoadFile cPath
		cIn = read(cPath)
		if len(cIn) > nRppCap
			This.Grow(len(cIn))
		ok
		This.Poke(0, cIn)
		return len(cIn)

	func SaveFile cPath, nLen
		This.CheckRange(0, nLen, "SaveFile")
		write(cPath, This.Peek(0, nLen))

	### ---- the escape hatch, named so it stays visible ----

	func AddressUnchecked
		return This.Base()

	func PokeUnchecked nOffset, cBytes
		setptr(pRppScratch, This.Base() + nOffset)
		pSrc = nullptr()
		setptr(pSrc, getptr(varptr(:cBytes, "char *")))
		memcpy(pRppScratch, pSrc, len(cBytes))

	### ---- the guard ----

	func CheckRange nOffset, nLen, cOp
		if not isnumber(nOffset) or not isnumber(nLen)
			raise("Rpp: " + cOp + " — offset and length must be numbers")
		ok
		if nOffset < 0 or nLen < 0
			raise("Rpp: " + cOp + " out of range — offset " + nOffset +
			      ", length " + nLen + ", capacity " + nRppCap)
		ok
		if nOffset + nLen > nRppCap
			raise("Rpp: " + cOp + " out of range — offset " + nOffset +
			      ", length " + nLen + ", capacity " + nRppCap)
		ok

### A window into a buffer. Holds a reference to its owner, so the bytes
### cannot be freed while the view is alive.

class RppView

	### THESE NAMES ARE DELIBERATELY UGLY, AND THAT IS THE FIX.
	###
	### They were `oBuf`, `nOff`, `nLen` -- the three most natural names a
	### caller would also use. In Ring an attribute assignment inside a class
	### can resolve against a caller variable of the same name and CLOBBER IT,
	### and a bare `oBuf` on its own line does not create a property at all.
	### The result, from examples/05:
	###
	###     nOff = 0
	###     for i = 1 to nRecs
	###         nLen  = oBuf.PeekInt32(nOff)
	###         oView = oBuf.View(nOff + 4, nLen)   # <-- destroyed nOff and nLen
	###         nOff += 4 + nLen
	###     next
	###
	### walked off the records and raised a bounds error 200 bytes later.
	### With the caller's buffer also named `oBuf`, the class-body initialiser
	### itself raised Error (R31), "Trying to destroy the object using the
	### self reference".
	###
	### A prefix nobody types by accident costs nothing and removes the whole
	### class of failure. Found by writing an example, not by a test.
	oRppOwner = NULL
	nRppOff   = 0
	nRppLen   = 0

	func init oBuffer, nOffset, nLength
		# ref() is load-bearing. Plain assignment COPIES the object, and the
		# view would then read a snapshot of the buffer taken at View() time
		# -- writes made through the buffer afterwards would be invisible.
		# It is a window, not a copy; that is the whole point of the type.
		oRppOwner = ref(oBuffer)
		nRppOff   = nOffset
		nRppLen   = nLength

	func Size
		return nRppLen

	func Offset
		return nRppOff

	func Peek nOffset, nCount
		if nOffset < 0 or nCount < 0 or nOffset + nCount > nRppLen
			raise("Rpp: view Peek out of range — offset " + nOffset +
			      ", length " + nCount + ", view length " + nRppLen)
		ok
		return oRppOwner.Peek(nRppOff + nOffset, nCount)

	func Byte nOffset
		return ascii(This.Peek(nOffset, 1))

	func Sub nOffset, nCount
		if nOffset < 0 or nCount < 0 or nOffset + nCount > nRppLen
			raise("Rpp: view Sub out of range — offset " + nOffset +
			      ", length " + nCount + ", view length " + nRppLen)
		ok
		return new RppView(oRppOwner, nRppOff + nOffset, nCount)

	func Str
		return This.Peek(0, nRppLen)

	func Buffer
		return oRppOwner
