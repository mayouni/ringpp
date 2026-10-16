# What comes out of a container, as the type table sees it -- three shapes
# where it claimed a class the value did not have.
#
# 1. A NON-MONOTONE RULE. `pv[i]` was typed as pv's ELEMENT class, and an
#    element class nothing has revealed is the lattice's BOTTOM. So when a
#    call site walked early made pv a string, `a = pv[i]` became a string;
#    when a later call site widened pv to "anything", pv[i] fell to bottom
#    and the string claim was never taken back. len(a) then compiled as a
#    STRING length and raised "Bad parameter type!" on a pair -- the line
#    agentic/agentfile stopped on, in _StzOutputVerifyFields.
# 2. A PARAMETER'S ELEMENTS come from its caller. `p[1] = 0` inside the
#    function proved nothing about p[2].
# 3. A LIST PASSED TO A CALL is passed by reference (C-7), and the callee
#    may fill it with anything. add(aL, 1) before the call proved nothing
#    about what the call added.
#
# Rows 2 and 3 compute `x + 1` on what is really a string, so a claimed
# integer shows as a wrong number rather than as Ring's "b1".

A()
B()
? "2 " + SetFirst(["a", "b"])
? "3 " + Escape()

func A
	V("ab")

func V(pv)
	for i = 1 to len(pv)
		a = pv[i]
		if isList(a) and len(a) = 2
			? "1 a pair at " + i
		ok
	next

func B
	V([[1, 2], 5])

func SetFirst(p)
	p[1] = 0
	x = p[2]
	return x + 1

func Escape
	aL = []
	add(aL, 1)
	Fill(aL)
	x = aL[2]
	return x + 1

func Fill(p)
	add(p, "b")
