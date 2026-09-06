class T
	# MUST FIRE: loadlib is in this closure, and it cannot have created a
	# variable. Before the split this line was silent.
	def Go(pcStr)
		return len(pcStr) + $_nMissing_

	# MUST STAY SILENT: a transparent eval names what it assigns, so
	# $_seen_ is as defined as an assignment would make it.
	def Seen()
		eval("$_seen_ = 1")
		return $_seen_
