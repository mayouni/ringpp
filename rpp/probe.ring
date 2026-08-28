### Ring++ — the declared compatibility surface, verified by behaviour.
###
### Ring++ rests on about thirty names. This file asserts, at load time and in
### well under a second, that this Ring still BEHAVES the way Ring++ assumes —
### not merely that the names exist. A build that passes is supported whatever
### it calls itself; a build that fails is not, whatever it calls itself.
### See docs/DESIGN.md §5.

# Degradation policy per row.
RPP_HARD = 1     # the facility is unavailable; using it raises
RPP_SOFT = 2     # a slower path takes over; RppReport() says so
RPP_INFO = 3     # recorded, no behavioural effect

RPP_PROBES  = []     # [name, policy, ok, detail]
RPP_OK      = TRUE   # every HARD row passed
RPP_LITTLE_ENDIAN = TRUE

func RppProbeAll
	RPP_PROBES = []

	# --- the load-bearing assumption: varptr gives a live, writable pointer
	cB = space(16)
	p = varptr(:cB, "char *")
	memcpy(p, "ABCD", 4)
	_RppRow("varptr-write-through", RPP_HARD,
		left(cB, 4) = "ABCD",
		"memcpy through varptr(:name) must mutate the variable in place")

	# --- and that the address does not move while the string is only read
	n1 = getptr(varptr(:cB, "char *"))
	for i = 1 to 3
		x = cB
	next
	n2 = getptr(varptr(:cB, "char *"))
	_RppRow("varptr-address-stable", RPP_HARD, n1 = n2,
		"the pointer must survive the variable being read")

	# --- ptr2str is the O(1) slice Ring++ is built on
	cS = "HELLO WORLD"
	q = varptr(:cS, "char *")
	_RppRow("ptr2str-slice", RPP_HARD, ptr2str(q, 6, 5) = "WORLD",
		"ptr2str(p, offset, len) must read at an offset")

	# --- FINDINGS F-14: does memcpy survive a source with a leading zero byte?
	# Not required (Ring++ never passes a string source), but it tells the user
	# whether their Ring carries the fix, and RppReport prints it.
	_RppRow("memcpy-nul-source-fixed", RPP_INFO, _RppMemcpyNulOk(),
		"ring-lang/ring#1643 — memcpy() with a leading-zero string source")

	# --- packing round-trips, and the byte order of this machine
	_RppRow("pack-int32",  RPP_HARD, bytes2int(int2bytes(123456)) = 123456, "int2bytes/bytes2int")
	_RppRow("pack-double", RPP_HARD, bytes2double(double2bytes(1.5)) = 1.5,  "double2bytes/bytes2double")
	RPP_LITTLE_ENDIAN = (str2hex(int2bytes(1)) = "01000000")
	_RppRow("byte-order", RPP_INFO, TRUE,
		"" + _RppIff(RPP_LITTLE_ENDIAN, "little", "big") + "-endian")

	# --- the list phase: genarray speeds a permuted read, and one add drops it
	_RppRow("genarray", RPP_SOFT, _RppGenArrayOk(),
		"ringvm_genarray must build an items array and one append must free it")

	# --- sub-interpreters, for RppSandbox
	_RppRow("substate", RPP_SOFT, _RppSubStateOk(),
		"ring_state_init/runcode/findvar/delete round trip")

	RPP_OK = TRUE
	for aRow in RPP_PROBES
		if aRow[2] = RPP_HARD and aRow[3] = FALSE
			RPP_OK = FALSE
		ok
	next
	return RPP_OK

func _RppRow cName, nPolicy, bOk, cDetail
	RPP_PROBES + [cName, nPolicy, bOk, cDetail]

func _RppMemcpyNulOk
	# A leading-zero source aborts the process on Ring <= 1.27, so this cannot
	# be tested in-process. Detect the fix indirectly: the same misclassification
	# makes ptrcmp() see a binary string as a NULL pointer.
	cZero = int2bytes(256)          # 00010000
	bOk = FALSE
	try
		bOk = (ptrcmp(cZero, nullptr()) = 0)
	catch
		bOk = TRUE                  # rejected as a non-pointer = correct
	done
	return bOk

func _RppGenArrayOk
	nN = 400
	a = list(nN)
	for i = 1 to nN a[i] = i next
	ringvm_genarray(a)
	bRead = (a[nN/2] = nN/2)
	a + 1                            # must invalidate
	return bRead and (a[nN/2] = nN/2)

func _RppSubStateOk
	bOk = FALSE
	try
		st = ring_state_init()
		ring_state_runcode(st, "rppx = 42")
		v = ring_state_findvar(st, "rppx")     # lower case on purpose: F-3
		bOk = (not isnumber(v)) and (v[3] = 42)
		ring_state_delete(st)
	catch
		bOk = FALSE
	done
	return bOk

func RppReport
	? "Ring++ probe — Ring " + _RppVersion()
	for aRow in RPP_PROBES
		cP = "info"
		if aRow[2] = RPP_HARD cP = "HARD" ok
		if aRow[2] = RPP_SOFT cP = "soft" ok
		? "  " + _RppIff(aRow[3], "ok  ", "FAIL") + "  " +
		  _RppPad(aRow[1], 24) + " " + _RppPad(cP, 5) + " " + aRow[4]
	next
	? "  --> " + _RppIff(RPP_OK, "supported", "NOT SUPPORTED — see the HARD rows above")

func RppOk
	return RPP_OK

func _RppVersion
	cV = "?"
	try
		cV = "" + version
	catch
		cV = "unknown"
	done
	return cV

func _RppPad cStr, n
	if len(cStr) >= n return cStr ok
	return cStr + copy(" ", n - len(cStr))

### PREFIXED, AND THAT IS A BUG FIX. This was `iff` — the ONLY unprefixed
### global in the whole library, every other name being Rpp/_Rpp. Ring
### allows one definition of a name per program (C22), so claiming a helper
### name that common made Ring++ UNLOADABLE beside any project that has its
### own: `load "ringpp.ring"` next to Softanza died with
### "Error (C22) : Function redefinition, function is already defined!"
### before a line of either library ran.
###
### Found by writing docs/CASE-SOFTANZA.md — the first time the two were
### asked to sit in one program. A dependency-free library that cannot be
### loaded alongside the library it was built for is not dependency-free.
func _RppIff bCond, vThen, vElse
	if bCond return vThen else return vElse ok
