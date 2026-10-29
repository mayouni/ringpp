# `rnxc migrate` must list EVERY use of a top-level global written bare in a function -- the gate step `migrate lists
# every site` reads this file. Each line marked `# site` is one; `nUnset` is no global (assigned nowhere), so it is not.
# Before 2026-10-29 the `++`, add(), insert() and del() lines were filed as a bare `identifier` and migrate skipped them.
nCount = 0
aL = [1]
? Bump()

func Bump
	nCount++              # site
	add(aL, 2)            # site
	insert(aL, 1, 0)      # site
	del(aL, 1)            # site
	aL[1] = 5             # site
	nUnset++
	return nCount         # site
