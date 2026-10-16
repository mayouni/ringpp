### 16 — An EMPTY catch block leaks a VM stack slot (FINDINGS F-16)
###
### ringvm_info()[18] is pVM->nSP. RING_VM_STACK_SIZE is 1004 (vm.h), so
### about 1003 consecutive empty-catch raises kill the program with
###     Error (R4) : Stack Overflow
### ...from code that contains no recursion and no deep nesting at all.
###
### The last arm is commented out because it does not survive.

func SP  return ringvm_info()[18]

func main
	K = 300
	? "K = " + K + " caught raises per arm; RING_VM_STACK_SIZE = 1004"
	? ""

	n0 = SP()
	for i = 1 to K
		try  raise("x")  catch  done
	next
	? "  1  EMPTY catch                    SP " + n0 + " -> " + SP() + "   <-- LEAKS 1 per catch"

	nSink = 0
	n0 = SP()
	for i = 1 to K
		try  raise("x")  catch  nSink++  done
	next
	? "  2  catch with one statement       SP " + n0 + " -> " + SP()

	n0 = SP()
	for i = 1 to K
		try  raise("x")  catch  c = cCatchError  done
	next
	? "  3  catch reading cCatchError      SP " + n0 + " -> " + SP()

	n0 = SP()
	for i = 1 to K
		try  nSink++  catch  done
	next
	? "  4  empty catch, body never raises SP " + n0 + " -> " + SP()

	n0 = SP()
	for i = 1 to K
		try  raise("x")  catch  done
		nSink = i + 1
	next
	? "  5  empty catch + a later statement SP " + n0 + " -> " + SP()

	? ""
	? "  Only arm 1 grows. Any statement in the catch block -- or any"
	? "  statement after the try -- drains the slot."
	? ""
	? "  Uncomment the arm below to see it die at ~1003:"
	? "      for i = 1 to 1100"
	? "          try  raise(\"x\")  catch  done"
	? "      next"
	? "      --> Error (R4) : Stack Overflow"
