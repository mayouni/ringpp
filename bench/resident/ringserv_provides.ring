# RingServ's own proof that its library loaded (src/bridge.zig, rs_init): after
# each ringlib file, the host asks whether the function that file promises
# exists. Asked here for all fourteen, after the files were admitted.
? "provides: " + RppResidentProvides()

func RppResidentProvides
	aP = ["jsonencode", "__dispatch", "dataquery", "rsrungeneric", "rscontractcheck", "__rs_topology", "__rs_sync_push", "rsjsdispatch", "rsactorcheck", "journalappend", "rsgesturecall", "family", "rsconfigfold", "ask"]
	nHave = 0
	for cP in aP
		if isFunction(cP)
			nHave++
		else
			? "missing: " + cP
		ok
	next
	return "" + nHave + " of " + len(aP)
