### Ring++ — the named decisions.
###
### Each facility here is a "when", not a "how": the programmer says when,
### the library makes saying it pleasant, safe, and honest about the cost.
### Nothing here is invented; every one rests on a Ring primitive.
###
### FILE LAYOUT IS LOAD-BEARING: in Ring, every `func` after the first
### `class` becomes a METHOD of that class. All functions must come first.
### Getting this wrong produces "Calling Function without definition" at a
### call site that looks perfectly correct.

RPP_ADVICE = []          # collected at runtime; RppAdvise() prints it

func RppAdviseAdd cWhere, cText
	RPP_ADVICE + [cWhere, cText]

func RppAdvise
	if len(RPP_ADVICE) = 0
		? "Ring++ advice: nothing to report."
		return
	ok
	? "Ring++ advice — " + len(RPP_ADVICE) + " item(s)"
	for aA in RPP_ADVICE
		? "  " + aA[1] + ": " + aA[2]
	next

func RppAdviceClear
	RPP_ADVICE = []

func RppIndexed aList
	return new RppIndexed(aList)

### RppRows — the 2D idiom (FINDINGS F-12): list(rows, cols) is ~6x faster
### than pushing sublists, because it uses the block allocator. It also gives
### near-array random access for free (F-19).
func RppRows nRows, nCols
	if nRows < 1 or nCols < 1
		raise("Rpp: RppRows needs positive dimensions, got " +
		      nRows + " x " + nCols)
	ok
	return list(nRows, nCols)

func RppSandbox
	return new RppSandbox()

### The scanner, as a service. Ring's own front end, no extension.
func RppSyntaxOk cCode
	st = ring_state_init()
	aT = ring_state_stringtokens(st, cCode)
	nErr = ring_state_scannererror(st)
	ring_state_delete(st)
	return (nErr = 0)

func RppTokens cCode
	st = ring_state_init()
	aT = ring_state_stringtokens(st, cCode)
	ring_state_delete(st)
	return aT

### ---------------------------------------------------------------------
### RppIndexed — the genarray PHASE.
###
### ringvm_genarray is worth ~150-200x on an APPEND-BUILT list read at
### random, and up to 16x WORSE when mutations outnumber reads (FINDINGS
### F-9, F-10, F-19). It is a property of a phase, not of a list, so it is
### spelled as one: open a phase, read, close it.
###
###     oIdx = RppIndexed(aRows)
###     ... many random reads ...
###     oIdx.Release(aRows)
###
### Ring forces the list to be passed to BOTH calls: storing it in an
### attribute would copy it by value, and we would index the copy.
###
### If you control how the list is built, `list(n)` may make this
### unnecessary — a block-allocated list is already ~200x faster at random
### access than an append-built one (F-19).

class RppIndexed

	nSizeAtOpen = 0
	lApplied    = FALSE
	cWhy        = ""

	func init aList
		nSizeAtOpen = len(aList)
		if nSizeAtOpen < RPP_INDEX_MIN_SIZE
			lApplied = FALSE
			cWhy = "list has " + nSizeAtOpen + " items; below " +
			       RPP_INDEX_MIN_SIZE + " the cursor walk is cheaper than the array"
			return
		ok
		ringvm_genarray(aList)
		lApplied = TRUE
		cWhy = "items array built for " + nSizeAtOpen + " items"

	func Applied
		return lApplied

	func Why
		return cWhy

	### Closing the phase. Returns TRUE when the index was still valid.
	func Release aList
		if not lApplied
			return FALSE
		ok
		if len(aList) != nSizeAtOpen
			RppAdviseAdd("RppIndexed",
			  "the list changed size during the phase (" + nSizeAtOpen +
			  " -> " + len(aList) + "). One append frees the items array, so " +
			  "reads after that point walked the list. Open the phase after " +
			  "the mutations, not around them.")
			return FALSE
		ok
		return TRUE

	### What this CANNOT see, stated rather than hidden:
	### sort() and reverse() free the items array WITHOUT changing len(),
	### so a phase that sorts mid-way reports valid and is not. Verified.
	func Caveat
		return "sort() and reverse() invalidate the index without changing " +
		       "len(), so Release() cannot detect them. Re-open the phase " +
		       "after sorting."

### ---------------------------------------------------------------------
### RppSandbox — a second interpreter, for containment (FINDINGS F-13).
###
### 0.35 ms to create. A Ring error inside does NOT kill the host. It buys
### containment, not speed: the same work runs ~1.75x slower in a fresh
### sub-state than in the host.
###
### `Get` and `Set` are not available as method names — `get` and `put` are
### Ring statement keywords and never demote to identifiers.

class RppSandbox

	pState
	lOpen = FALSE

	func init
		pState = ring_state_init()
		lOpen = TRUE

	func Run cCode
		This.Alive("Run")
		ring_state_runcode(pState, cCode)
		return This

	func Quiet
		This.Alive("Quiet")
		ring_state_runcode(pState, "ringvm_hideerrormsg(1)")
		return This

	### Reads a variable back. Ring stores identifiers folded to LOWER CASE
	### and ring_state_findvar does a raw lookup, so "nTotal" silently misses
	### while "ntotal" works — and absence is reported as the NUMBER 0, which
	### is indistinguishable from a variable holding 0 (FINDINGS F-3).
	### Both traps are closed here.
	func Var cName
		This.Alive("Var")
		v = ring_state_findvar(pState, lower(cName))
		if isnumber(v)
			raise("Rpp: sandbox has no variable '" + cName + "'")
		ok
		return v[3]

	func Has cName
		This.Alive("Has")
		v = ring_state_findvar(pState, lower(cName))
		return not isnumber(v)

	### F-33: `ring_state_setvar` ASSIGNS to a variable the sub-state already
	### has. Handed a name it has never seen it raises Ring's own
	### "R6: Variable is required" from inside the C function -- naming
	### neither the variable nor the reason, and from a place the caller
	### cannot see. `ring_state_newvar` does not help; it raises the same
	### thing. Measured 2026-08-25.
	###
	### But the documented use of SetVar is "set a variable BEFORE running
	### code that reads it", so absence is the normal case, not an error.
	### Declare it first, then assign. The VALUE never travels through
	### runcode -- only the name does, and only after it is checked to be a
	### plain identifier, so a name can never smuggle a statement in.
	func SetVar cName, vValue
		This.Alive("SetVar")
		if not This.Has(cName)
			if not This.IsPlainName(cName)
				raise("Rpp: SetVar cannot declare '" + cName +
				      "' — a name to be created must be letters, digits " +
				      "and _ only, not starting with a digit")
			ok
			ring_state_runcode(pState, lower(cName) + " = 0")
		ok
		ring_state_setvar(pState, lower(cName), vValue)
		return This

	### Deliberately not a regex: the library depends on nothing but the VM
	### surface it declares, and ascii() is already on that list.
	func IsPlainName cName
		if not isstring(cName) return FALSE ok
		nRppNameLen = len(cName)
		if nRppNameLen = 0 return FALSE ok
		### Hoisted, never in the header: `for i = 1 to len(s)` re-evaluates
		### len(s) EVERY iteration and each evaluation copies the whole
		### string to the call (F-41). Harmless on an identifier this short;
		### hoisted anyway so no reader copies the trap out of this library.
		for i = 1 to nRppNameLen
			n = ascii(cName[i])
			if (n >= 65 and n <= 90) or (n >= 97 and n <= 122) or n = 95
				loop
			ok
			if (n >= 48 and n <= 57) and i > 1
				loop
			ok
			return FALSE
		next
		return TRUE

	func Free
		if lOpen
			ring_state_delete(pState)
			lOpen = FALSE
		ok

	func IsOpen
		return lOpen

	func Alive cOp
		if not lOpen
			raise("Rpp: sandbox already freed — cannot " + cOp)
		ok
